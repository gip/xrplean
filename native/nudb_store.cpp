#include "nudb_store.h"
#include <cstdlib>
#include <cstring>
#include <string>

static thread_local std::string last_error;
extern "C" const char *lx_nudb_error(void) { return last_error.c_str(); }

#if LX_WITH_NUDB
#include <nudb/nudb.hpp>
#include <array>
#include <filesystem>
#include <iomanip>
#include <limits>
#include <map>
#include <memory>
#include <mutex>
#include <sstream>
#include <stdexcept>
#include <fcntl.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>
#ifdef __APPLE__
#include <sys/clonefile.h>
#endif

namespace {
namespace fs = std::filesystem;
using Key = std::array<unsigned char, 32>;
void check(nudb::error_code const& ec) { if (ec) throw std::runtime_error(ec.message()); }
void require(bool ok, char const *what) { if (!ok) throw std::runtime_error(what); }
bool generation_name(std::string const& name) {
    if (name.size() != 34 || name.substr(0, 2) != "g-") return false;
    for (auto c : name.substr(2)) if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return false;
    return true;
}
void sync_directory(fs::path const& directory) {
    int fd = ::open(directory.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
    require(fd >= 0, "cannot open NuDB directory for sync");
    int result; do { result = ::fsync(fd); } while (result && errno == EINTR);
    ::close(fd); require(result == 0, "NuDB directory sync failed");
}
void private_directory(fs::path const& path) {
    struct stat info;
    require(::lstat(path.c_str(), &info) == 0 && S_ISDIR(info.st_mode) && info.st_uid == ::getuid(),
            "NuDB directory must be owned by this user and not a symlink");
}
fs::path base_path(char const* database) { return fs::absolute(std::string(database) + ".nodes").lexically_normal(); }
fs::path checked_path(char const* database, char const* generation) {
    require(generation_name(generation), "invalid NuDB generation");
    auto base = base_path(database); private_directory(base);
    auto path = base / generation; private_directory(path);
    return fs::canonical(path);
}
void regular_file(fs::path const& path) {
    struct stat info;
    require(::lstat(path.c_str(), &info) == 0 && S_ISREG(info.st_mode) && info.st_uid == ::getuid(),
            "invalid NuDB generation file");
}
uint64_t generation_bytes(fs::path const& path) {
    uint64_t result = 0;
    for (auto const& entry : fs::directory_iterator(path)) {
        regular_file(entry.path()); result += fs::file_size(entry.path());
    }
    return result;
}
struct File : nudb::native_file {
    void sync(nudb::error_code& ec) {
        // Fault injection is opt-in and exercised by the storage recovery tests.
        auto fault = std::getenv("LEANXRPL_STORAGE_TEST_FAULT");
        if (fault && std::strcmp(fault, "sync-error") == 0) {
            ec = boost::system::errc::make_error_code(nudb::errc::io_error); return;
        }
        nudb::native_file::sync(ec);
    }
};
using Database = nudb::basic_store<nudb::xxhasher, File>;
struct Core {
    fs::path path;
    int lock = -1;
    std::mutex mutex;
    nudb::context context;
    Database db{context}; // Manual flush; no background thread.
    bool retired = false;
    uint64_t disk_bytes = 0, pending_bytes = 0;
    explicit Core(fs::path p) : path(std::move(p)) {
        auto owner = path / "owner.lock";
        lock = ::open(owner.c_str(), O_CREAT | O_RDWR | O_NOFOLLOW, 0600);
        struct stat info;
        if (lock < 0 || ::fstat(lock, &info) || !S_ISREG(info.st_mode) || info.st_uid != ::getuid() ||
            ::flock(lock, LOCK_EX | LOCK_NB)) {
            if (lock >= 0) ::close(lock);
            lock = -1; throw std::runtime_error("NuDB generation is owned by another process");
        }
        try {
            for (auto const& entry : fs::directory_iterator(path)) regular_file(entry.path());
            nudb::error_code ec;
            db.open((path / "nudb.dat").string(), (path / "nudb.key").string(),
                    (path / "nudb.log").string(), ec); check(ec);
            require(db.appnum() == 0x4c584e31 && db.key_size() == 32, "not a leanxrpl NuDB generation");
            db.set_burst(std::numeric_limits<std::size_t>::max());
            sync_directory(path); // Persist the newly created recovery log entry.
            disk_bytes = generation_bytes(path);
        } catch (...) {
            nudb::error_code ec; db.close(ec); ::close(lock); lock = -1; throw;
        }
    }
    ~Core() {
        nudb::error_code ec; db.close(ec);
        // Keep the owner lock while removing a retired generation.
        if (retired) { std::error_code ignored; fs::remove_all(path, ignored); }
        if (lock >= 0) ::close(lock);
    }
};
struct Handle { std::shared_ptr<Core> core; };
std::mutex registry_mutex;
std::map<std::string, std::weak_ptr<Core>> registry;
Core& core(void *handle) { return *static_cast<Handle*>(handle)->core; }
void flush(Core& c, uint64_t budget) {
    c.context.flush();
    // NuDB latches flush errors; fetch propagates that error even for a missing key.
    Key zero{}; nudb::error_code ec;
    c.db.fetch(zero.data(), [](void const*, std::size_t) {}, ec);
    if (ec != nudb::error::key_not_found) check(ec);
    c.disk_bytes = generation_bytes(c.path); c.pending_bytes = 0;
    require(c.disk_bytes <= budget, "NuDB allocation limit exceeded");
}
}

#define LX_TRY try
#define LX_CATCH(result) catch (std::exception const& e) { last_error = e.what(); return result; } catch (...) { last_error = "unknown NuDB error"; return result; }
extern "C" int lx_nudb_available(void) { return 1; }
extern "C" int lx_nudb_new_generation(char out[35]) {
    LX_TRY {
        std::ostringstream text;
        text << "g-" << std::hex << std::setfill('0') << std::setw(16) << nudb::make_uid()
             << std::setw(16) << nudb::make_uid();
        std::memcpy(out, text.str().c_str(), 35); return 1;
    } LX_CATCH(0)
}
extern "C" void *lx_nudb_open(char const* database, char const* generation, int create) {
    LX_TRY {
        require(generation_name(generation), "invalid NuDB generation");
        auto base = base_path(database);
        if (create) {
            if (fs::create_directory(base)) {
                ::chmod(base.c_str(), 0700); sync_directory(base.parent_path());
            }
            private_directory(base);
            auto path = base / generation;
            require(fs::create_directory(path), "NuDB generation already exists");
            ::chmod(path.c_str(), 0700);
            nudb::error_code ec;
            nudb::create<nudb::xxhasher, File>((path / "nudb.dat").string(),
                (path / "nudb.key").string(), (path / "nudb.log").string(),
                0x4c584e31, nudb::make_uid(), nudb::make_salt(), 32, 4096, 0.5, ec);
            check(ec);
        }
        auto path = checked_path(database, generation);
        std::lock_guard<std::mutex> guard(registry_mutex);
        for (auto it = registry.begin(); it != registry.end();) {
            if (it->second.expired()) it = registry.erase(it); else ++it;
        }
        auto shared = registry[path.string()].lock();
        if (!shared) {
            shared = std::make_shared<Core>(path); registry[path.string()] = shared;
        }
        if (create) {
            flush(*shared, std::numeric_limits<uint64_t>::max());
            // An empty new database still needs durable initial headers.
            for (auto name : {"nudb.dat", "nudb.key"}) {
                int fd = ::open((path / name).c_str(), O_RDONLY | O_NOFOLLOW);
                require(fd >= 0, "open NuDB initial header");
                int result = ::fsync(fd); ::close(fd); require(result == 0, "sync NuDB initial header");
            }
            sync_directory(path); sync_directory(base);
        }
        return new Handle{std::move(shared)};
    } LX_CATCH(nullptr)
}
extern "C" int lx_nudb_get(void *handle, void const* hash, unsigned char **data, size_t *size) {
    *data = nullptr; *size = 0;
    LX_TRY {
        auto& c = core(handle); std::lock_guard<std::mutex> guard(c.mutex);
        nudb::error_code ec;
        c.db.fetch(hash, [&](void const* value, std::size_t length) {
            auto p = static_cast<unsigned char const*>(value);
            require(length >= 1 && length <= 2097153 && p[0] == 1, "invalid leanxrpl NuDB value format");
            *size = length - 1; *data = static_cast<unsigned char*>(std::malloc(*size ? *size : 1));
            require(*data != nullptr, "NuDB read allocation failed");
            if (*size) std::memcpy(*data, p + 1, *size);
        }, ec);
        if (ec == nudb::error::key_not_found) return 1;
        check(ec); return 1;
    } LX_CATCH(0)
}
extern "C" int lx_nudb_clone(void *handle, char const* target) {
    LX_TRY {
        auto& c = core(handle); std::lock_guard<std::mutex> guard(c.mutex);
        require(c.pending_bytes == 0, "clone requires a flushed source");
        fs::path base = std::string(target) + ".nodes";
        require(fs::create_directory(base), "clone node directory already exists");
        require(::chmod(base.c_str(), 0700) == 0, "clone node directory permissions");
        auto generation = base / c.path.filename();
        require(fs::create_directory(generation), "clone generation already exists");
        require(::chmod(generation.c_str(), 0700) == 0, "clone generation permissions");
        for (auto name : {"nudb.dat", "nudb.key", "nudb.log"}) {
            auto source = c.path / name, destination = generation / name;
            if (!fs::exists(source)) continue;
            bool copied = false;
#ifdef __APPLE__
            copied = ::clonefile(source.c_str(), destination.c_str(), 0) == 0;
#endif
            if (!copied) require(fs::copy_file(source, destination), "clone file copy failed");
            int fd = ::open(destination.c_str(), O_RDONLY | O_NOFOLLOW);
            require(fd >= 0, "open cloned node file");
            int synced = ::fsync(fd); ::close(fd); require(synced == 0, "sync cloned node file");
        }
        sync_directory(generation); sync_directory(base); return 1;
    } LX_CATCH(0)
}
static int put_node(void *handle, void const* hash, void const* data, size_t size, uint64_t budget, bool compare_existing) {
    LX_TRY {
        require(size <= 2097152, "NuDB node size limit");
        auto& c = core(handle); std::lock_guard<std::mutex> guard(c.mutex);
        std::string value(1, '\1'); value.append(static_cast<char const*>(data), size);
        bool room = c.disk_bytes <= budget && c.pending_bytes <= budget - c.disk_bytes &&
            size + 128 <= budget - c.disk_bytes - c.pending_bytes;
        if (!room) {
            nudb::error_code ec; bool present = false;
            c.db.fetch(hash, [&](void const* p, std::size_t n) {
                if(compare_existing)require(n == value.size() && std::memcmp(p, value.data(), n) == 0,
                    "conflicting bytes for existing NuDB node"); present = true;
            }, ec);
            if (ec != nudb::error::key_not_found) check(ec);
            require(present, "NuDB allocation limit exceeded");
            return compare_existing?1:2;
        }
        nudb::error_code ec; c.db.insert(hash, value.data(), value.size(), ec);
        if (ec == nudb::error::key_exists) {
            if(!compare_existing)return 2;
            ec = {};
            c.db.fetch(hash, [&](void const* p, std::size_t n) {
                require(n == value.size() && std::memcmp(p, value.data(), n) == 0,
                    "conflicting bytes for existing NuDB node");
            }, ec);
        } else if (!ec) c.pending_bytes += size + 128;
        check(ec); return 1;
    } LX_CATCH(0)
}
extern "C" int lx_nudb_put(void *handle, void const* hash, void const* data, size_t size, uint64_t budget) {
    return put_node(handle,hash,data,size,budget,true);
}
extern "C" int lx_nudb_put_new(void *handle, void const* hash, void const* data, size_t size, uint64_t budget) {
    return put_node(handle,hash,data,size,budget,false);
}
extern "C" int lx_nudb_flush(void *handle, uint64_t budget) {
    LX_TRY { auto& c = core(handle); std::lock_guard<std::mutex> guard(c.mutex); flush(c, budget); return 1; } LX_CATCH(0)
}
extern "C" int lx_nudb_bytes(void *handle, uint64_t *bytes) {
    LX_TRY { auto& c = core(handle); std::lock_guard<std::mutex> guard(c.mutex); *bytes = generation_bytes(c.path); return 1; } LX_CATCH(0)
}
extern "C" void lx_nudb_release(void *handle) { delete static_cast<Handle*>(handle); }
extern "C" void lx_nudb_retire(void *handle) {
    auto& c = core(handle); std::lock_guard<std::mutex> guard(c.mutex); c.retired = true;
}
extern "C" int lx_nudb_cleanup(char const* database, char const* active) {
    LX_TRY {
        auto base = base_path(database); if (!fs::exists(base)) return 1;
        private_directory(base);
        for (auto const& entry : fs::directory_iterator(base)) {
            auto name = entry.path().filename().string();
            if (name == active || !generation_name(name)) continue;
            private_directory(entry.path());
            int fd = ::open((entry.path() / "owner.lock").c_str(), O_CREAT | O_RDWR | O_NOFOLLOW, 0600);
            require(fd >= 0, "open obsolete NuDB generation lock");
            if (::flock(fd, LOCK_EX | LOCK_NB) == 0) {
                std::error_code error; fs::remove_all(entry.path(), error); ::close(fd);
                if (error) throw std::runtime_error(error.message());
            } else ::close(fd); // Existing reader still owns this generation.
        }
        sync_directory(base); return 1;
    } LX_CATCH(0)
}
#else
extern "C" int lx_nudb_available(void) { return 0; }
static int unavailable() { last_error = "NuDB support is unavailable; configure NUDB_PREFIX and BOOST_PREFIX, then rebuild"; return 0; }
extern "C" int lx_nudb_new_generation(char[35]) { return unavailable(); }
extern "C" void *lx_nudb_open(const char*, const char*, int) { unavailable(); return nullptr; }
extern "C" int lx_nudb_get(void*, const void*, unsigned char**, size_t*) { return unavailable(); }
extern "C" int lx_nudb_put(void*, const void*, const void*, size_t, uint64_t) { return unavailable(); }
extern "C" int lx_nudb_put_new(void*, const void*, const void*, size_t, uint64_t) { return unavailable(); }
extern "C" int lx_nudb_flush(void*, uint64_t) { return unavailable(); }
extern "C" int lx_nudb_bytes(void*, uint64_t*) { return unavailable(); }
extern "C" void lx_nudb_release(void*) {}
extern "C" void lx_nudb_retire(void*) {}
extern "C" int lx_nudb_cleanup(const char*, const char*) { return unavailable(); }
extern "C" int lx_nudb_clone(void*, const char*) { return unavailable(); }
#endif
