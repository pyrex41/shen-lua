-- libcurl multi interface via LuaJIT FFI.
--
-- Pins the OpenSSL soname (libcurl.so.4), not libcurl-gnutls. Option numbers
-- are libcurl's stable CINIT encoding, checked against the curl 8.5.0 headers
-- this spike was developed with. curl_multi_poll needs libcurl >= 7.66.

local ffi = require("ffi")

ffi.cdef[[
  typedef struct Curl_easy CURL;
  typedef struct Curl_multi CURLM;
  typedef int curl_socket_t;
  typedef int64_t curl_off_t;
  typedef int CURLcode;
  typedef int CURLoption;
  typedef int CURLINFO;
  typedef int CURLMcode;
  typedef int CURLMoption;
  typedef int CURLMSG;
  typedef int curl_infotype;

  struct curl_slist {
    char *data;
    struct curl_slist *next;
  };

  struct CURLMsg {
    CURLMSG msg;
    CURL *easy_handle;
    union {
      void *whatever;
      CURLcode result;
    } data;
  };

  struct curl_waitfd {
    curl_socket_t fd;
    short events;
    short revents;
  };

  typedef size_t (*unii_curl_write_cb)(char *ptr, size_t size, size_t nmemb, void *userdata);
  typedef int (*unii_curl_debug_cb)(CURL *handle, curl_infotype type, char *data, size_t size, void *userptr);

  CURLcode curl_global_init(long flags);
  void curl_global_cleanup(void);
  char *curl_version(void);

  CURL *curl_easy_init(void);
  void curl_easy_cleanup(CURL *curl);
  CURLcode curl_easy_setopt(CURL *curl, CURLoption option, ...);
  CURLcode curl_easy_getinfo(CURL *curl, CURLINFO info, ...);
  const char *curl_easy_strerror(CURLcode code);

  CURLM *curl_multi_init(void);
  CURLMcode curl_multi_cleanup(CURLM *multi_handle);
  CURLMcode curl_multi_add_handle(CURLM *multi_handle, CURL *curl_handle);
  CURLMcode curl_multi_remove_handle(CURLM *multi_handle, CURL *curl_handle);
  CURLMcode curl_multi_perform(CURLM *multi_handle, int *running_handles);
  CURLMcode curl_multi_poll(CURLM *multi_handle, struct curl_waitfd *extra_fds,
                            unsigned int extra_nfds, int timeout_ms, int *ret);
  CURLMcode curl_multi_setopt(CURLM *multi_handle, CURLMoption option, ...);
  struct CURLMsg *curl_multi_info_read(CURLM *multi_handle, int *msgs_in_queue);
  const char *curl_multi_strerror(CURLMcode code);

  struct curl_slist *curl_slist_append(struct curl_slist *list, const char *str);
  void curl_slist_free_all(struct curl_slist *list);
]]

local ok, lib = pcall(ffi.load, "libcurl.so.4")
if not ok then
  error("unii.host.network: failed to load libcurl.so.4 (OpenSSL build): " .. tostring(lib))
end

-- CINIT(name, TYPE, n) => TYPE_BASE + n. LONG=0, OBJECT/STRING=10000,
-- FUNCTION=20000, OFF_T=30000. CURLINFO uses a separate type tag.
local LONG = 0
local OBJECT = 10000
local FUNCTION = 20000
local INFO_STRING = 0x100000
local INFO_LONG = 0x200000
local INFO_OFF_T = 0x600000

local M = {
  lib = lib,
  LONG = LONG,
  -- easy options
  URL = OBJECT + 2,
  ERRORBUFFER = OBJECT + 10,
  WRITEFUNCTION = FUNCTION + 11,
  WRITEDATA = OBJECT + 1,
  POSTFIELDS = OBJECT + 15,
  USERAGENT = OBJECT + 18,
  HTTPHEADER = OBJECT + 23,
  HEADERDATA = OBJECT + 29,
  CUSTOMREQUEST = OBJECT + 36,
  VERBOSE = LONG + 41,
  POST = LONG + 47,
  FOLLOWLOCATION = LONG + 52,
  POSTFIELDSIZE = LONG + 60,
  SSL_VERIFYPEER = LONG + 64,
  CAINFO = OBJECT + 65,
  MAXREDIRS = LONG + 68,
  HTTPGET = LONG + 80,
  SSL_VERIFYHOST = LONG + 81,
  DEBUGFUNCTION = FUNCTION + 94,
  DEBUGDATA = OBJECT + 95,
  CAPATH = OBJECT + 97,
  NOSIGNAL = LONG + 99,
  TCP_NODELAY = LONG + 121,
  TIMEOUT_MS = LONG + 155,
  CONNECTTIMEOUT_MS = LONG + 156,
  HEADERFUNCTION = FUNCTION + 79,
  FRESH_CONNECT = LONG + 74,
  FORBID_REUSE = LONG + 75,
  HTTP_VERSION = LONG + 84,
  PROTOCOLS = LONG + 181,
  REDIR_PROTOCOLS = LONG + 182,
  -- CURLPROTO_HTTP | CURLPROTO_HTTPS
  PROTO_HTTP_HTTPS = 3,
  HTTP_VERSION_1_1 = 2,
  HTTP_VERSION_2TLS = 4,
  -- info
  RESPONSE_CODE = INFO_LONG + 2,
  SIZE_UPLOAD_T = INFO_OFF_T + 7,
  REQUEST_SIZE = INFO_LONG + 12,
  -- messages and codes
  CURLMSG_DONE = 1,
  CURLM_OK = 0,
  CURLM_CALL_MULTI_PERFORM = -1,
  CURLMOPT_MAX_TOTAL_CONNECTIONS = LONG + 13,
  CURLE_OK = 0,
  CURLE_UNSUPPORTED_PROTOCOL = 1,
  CURLE_URL_MALFORMAT = 3,
  CURLE_COULDNT_RESOLVE_PROXY = 5,
  CURLE_COULDNT_RESOLVE_HOST = 6,
  CURLE_COULDNT_CONNECT = 7,
  CURLE_PARTIAL_FILE = 18,
  CURLE_WRITE_ERROR = 23,
  CURLE_OPERATION_TIMEDOUT = 28,
  CURLE_SSL_CONNECT_ERROR = 35,
  CURLE_ABORTED_BY_CALLBACK = 42,
  CURLE_GOT_NOTHING = 52,
  CURLE_SEND_ERROR = 55,
  CURLE_RECV_ERROR = 56,
  CURLE_SSL_CERTPROBLEM = 58,
  CURLE_SSL_CIPHER = 59,
  CURLE_PEER_FAILED_VERIFICATION = 60,
  CURLE_SSL_CACERT_BADFILE = 77,
  CURLE_SSL_SHUTDOWN_FAILED = 80,
  CURLE_SSL_CRL_BADFILE = 82,
  CURLE_SSL_ISSUER_ERROR = 83,
  CURLE_SSL_PINNEDPUBKEYNOTMATCH = 90,
  CURLE_SSL_INVALIDCERTSTATUS = 91,
  CURLE_SSL_CLIENTCERT = 98,
  -- debug infotypes
  INFO_HEADER_OUT = 2,
  INFO_DATA_OUT = 4,
  WRITEFUNC_ERROR = 0xFFFFFFFF,
  ERROR_SIZE = 256,
  GLOBAL_ALL = 3,
}

local inited = false

function M.global_init()
  if inited then return end
  local rc = tonumber(lib.curl_global_init(M.GLOBAL_ALL))
  if rc ~= 0 then
    error("curl_global_init failed: " .. tostring(rc))
  end
  inited = true
end

function M.version()
  M.global_init()
  return ffi.string(lib.curl_version())
end

function M.strerror(code)
  local p = lib.curl_easy_strerror(code)
  if p == nil then return "curl error " .. tostring(code) end
  return ffi.string(p)
end

function M.multi_strerror(code)
  local p = lib.curl_multi_strerror(code)
  if p == nil then return "curl multi error " .. tostring(code) end
  return ffi.string(p)
end

local long_t = ffi.typeof("long")

function M.set_long(easy, opt, n)
  return tonumber(lib.curl_easy_setopt(easy, opt, ffi.cast(long_t, n)))
end

function M.set_ptr(easy, opt, ptr)
  return tonumber(lib.curl_easy_setopt(easy, opt, ptr))
end

function M.get_long(easy, info)
  local n = ffi.new("long[1]")
  local rc = tonumber(lib.curl_easy_getinfo(easy, info, n))
  if rc ~= 0 then return nil, rc end
  return tonumber(n[0])
end

function M.get_off(easy, info)
  local n = ffi.new("int64_t[1]")
  local rc = tonumber(lib.curl_easy_getinfo(easy, info, n))
  if rc ~= 0 then return nil, rc end
  return tonumber(n[0])
end

-- Failures that happen before an HTTP request can have been processed.
-- TLS handshake failures are in this set even though TCP may already be up:
-- the HTTP request itself was not transmitted.
M.PRE_SEND = {
  [1] = true, [2] = true, [3] = true, [4] = true, [5] = true, [6] = true,
  [7] = true, [27] = true, [35] = true, [43] = true, [45] = true,
  [48] = true, [49] = true, [53] = true, [54] = true, [58] = true,
  [59] = true, [60] = true, [66] = true, [77] = true, [80] = true,
  [82] = true, [83] = true, [90] = true, [91] = true, [98] = true,
}

function M.tls_code(code)
  return code == 35 or code == 58 or code == 59 or code == 60 or code == 66
      or code == 77 or code == 80 or code == 82 or code == 83 or code == 90
      or code == 91 or code == 98
end

return M
