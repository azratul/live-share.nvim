-- AES-256-GCM encryption via LuaJIT FFI → OpenSSL libcrypto.
-- Falls back to a no-op passthrough when FFI or OpenSSL is unavailable.
--
-- Frame layout (encrypted):  [ 12-byte nonce ][ ciphertext ][ 16-byte GCM tag ]
-- Key length: 32 bytes (AES-256).  Nonce: 12 random bytes per message.
local M = {}
M.available = false

local ffi_ok, ffi = pcall(require, "ffi")
if not ffi_ok then
  function M.setup() end
  return M
end

pcall(
  ffi.cdef,
  [[
  typedef struct evp_cipher_ctx_st EVP_CIPHER_CTX;
  typedef struct evp_cipher_st     EVP_CIPHER;
  EVP_CIPHER_CTX *EVP_CIPHER_CTX_new(void);
  void            EVP_CIPHER_CTX_free(EVP_CIPHER_CTX *ctx);
  int EVP_EncryptInit_ex(EVP_CIPHER_CTX *ctx, const EVP_CIPHER *type,
                         void *impl, const unsigned char *key, const unsigned char *iv);
  int EVP_EncryptUpdate(EVP_CIPHER_CTX *ctx, unsigned char *out, int *outl,
                        const unsigned char *in, int inl);
  int EVP_EncryptFinal_ex(EVP_CIPHER_CTX *ctx, unsigned char *out, int *outl);
  int EVP_DecryptInit_ex(EVP_CIPHER_CTX *ctx, const EVP_CIPHER *type,
                         void *impl, const unsigned char *key, const unsigned char *iv);
  int EVP_DecryptUpdate(EVP_CIPHER_CTX *ctx, unsigned char *out, int *outl,
                        const unsigned char *in, int inl);
  int EVP_DecryptFinal_ex(EVP_CIPHER_CTX *ctx, unsigned char *out, int *outl);
  int EVP_CIPHER_CTX_ctrl(EVP_CIPHER_CTX *ctx, int type, int arg, void *ptr);
  const EVP_CIPHER *EVP_aes_256_gcm(void);
  int RAND_bytes(unsigned char *buf, int num);

  typedef struct env_md_ctx_st EVP_MD_CTX;
  typedef struct evp_md_st     EVP_MD;
  EVP_MD_CTX *EVP_MD_CTX_new(void);
  void        EVP_MD_CTX_free(EVP_MD_CTX *ctx);
  const EVP_MD *EVP_sha256(void);
  int EVP_DigestInit_ex(EVP_MD_CTX *ctx, const EVP_MD *type, void *impl);
  int EVP_DigestUpdate(EVP_MD_CTX *ctx, const void *d, size_t cnt);
  int EVP_DigestFinal_ex(EVP_MD_CTX *ctx, unsigned char *md, unsigned int *s);
]]
)

local lib

local function try_load(name)
  local ok, l = pcall(ffi.load, name)
  if ok then
    lib = l
    M.available = true
    return true
  end
  return false
end

-- Try common library names across Linux, macOS, Windows
for _, name in ipairs({
  "crypto",
  "libcrypto-3-x64",
  "libcrypto-1_1-x64",
  "libcrypto-3",
  "libcrypto-1_1",
  "libcrypto.so.3",
  "libcrypto.so.1.1",
  "libcrypto.dylib",
  "/run/current-system/sw/share/nix-ld/lib/libcrypto.so",
}) do
  if try_load(name) then
    break
  end
end

-- Called from commands.setup() to retry loading with a user-supplied path.
-- No-op if already available or if no path is given.
function M.setup(cfg)
  if M.available or not (cfg and cfg.openssl_lib) then
    return
  end
  try_load(cfg.openssl_lib)
end

local EVP_CTRL_GCM_SET_IVLEN = 0x9
local EVP_CTRL_GCM_GET_TAG = 0x10
local EVP_CTRL_GCM_SET_TAG = 0x11
local NONCE_LEN = 12
local TAG_LEN = 16

function M.random_bytes(n)
  if not M.available then
    return nil
  end
  local buf = ffi.new("unsigned char[?]", n)
  lib.RAND_bytes(buf, n)
  return ffi.string(buf, n)
end

function M.generate_key()
  return M.random_bytes(32)
end

-- Returns ciphertext .. tag.
function M.encrypt(plaintext, key, nonce)
  if not M.available then
    return plaintext
  end
  local ctx = lib.EVP_CIPHER_CTX_new()
  local out = ffi.new("unsigned char[?]", #plaintext + TAG_LEN)
  local outl = ffi.new("int[1]")
  local tag = ffi.new("unsigned char[?]", TAG_LEN)

  lib.EVP_EncryptInit_ex(ctx, lib.EVP_aes_256_gcm(), nil, nil, nil)
  lib.EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_IVLEN, NONCE_LEN, nil)
  lib.EVP_EncryptInit_ex(ctx, nil, nil, key, nonce)
  lib.EVP_EncryptUpdate(ctx, out, outl, plaintext, #plaintext)
  local ct_len = outl[0]
  lib.EVP_EncryptFinal_ex(ctx, out + ct_len, outl)
  ct_len = ct_len + outl[0]
  lib.EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_GET_TAG, TAG_LEN, tag)
  lib.EVP_CIPHER_CTX_free(ctx)

  return ffi.string(out, ct_len) .. ffi.string(tag, TAG_LEN)
end

-- Returns plaintext, or nil if authentication fails.
function M.decrypt(ciphertext_with_tag, key, nonce)
  if not M.available then
    return ciphertext_with_tag
  end
  if #ciphertext_with_tag < TAG_LEN then
    return nil
  end
  local ct_len = #ciphertext_with_tag - TAG_LEN

  local ctx = lib.EVP_CIPHER_CTX_new()
  local out = ffi.new("unsigned char[?]", ct_len + TAG_LEN)
  local outl = ffi.new("int[1]")
  local tag = ffi.new("unsigned char[?]", TAG_LEN)
  ffi.copy(tag, ciphertext_with_tag:sub(ct_len + 1), TAG_LEN)

  lib.EVP_DecryptInit_ex(ctx, lib.EVP_aes_256_gcm(), nil, nil, nil)
  lib.EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_IVLEN, NONCE_LEN, nil)
  lib.EVP_DecryptInit_ex(ctx, nil, nil, key, nonce)
  lib.EVP_DecryptUpdate(ctx, out, outl, ciphertext_with_tag, ct_len)
  local pt_len = outl[0]
  lib.EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_TAG, TAG_LEN, tag)
  local ok = lib.EVP_DecryptFinal_ex(ctx, out + pt_len, outl)
  lib.EVP_CIPHER_CTX_free(ctx)

  if ok ~= 1 then
    return nil
  end
  return ffi.string(out, pt_len + outl[0])
end

-- SHA-256.  Returns a 32-byte binary digest (or nil if OpenSSL is unavailable).
function M.sha256(input)
  if not M.available then
    return nil
  end
  local ctx = lib.EVP_MD_CTX_new()
  if ctx == nil then
    return nil
  end
  lib.EVP_DigestInit_ex(ctx, lib.EVP_sha256(), nil)
  lib.EVP_DigestUpdate(ctx, input, #input)
  local out = ffi.new("unsigned char[32]")
  local outl = ffi.new("unsigned int[1]")
  lib.EVP_DigestFinal_ex(ctx, out, outl)
  lib.EVP_MD_CTX_free(ctx)
  return ffi.string(out, outl[0])
end

-- Short, human-readable fingerprint of the session key for out-of-band
-- verification.  Format: "AB-CD-EF-12-34-67" (6 bytes hex, 47 bits of entropy).
-- Both host and guest derive this independently from the shared key, so a
-- mismatch means the URL fragment was rewritten in transit.
function M.fingerprint(key)
  if not key then
    return nil
  end
  local digest = M.sha256(key)
  if not digest or #digest < 6 then
    return nil
  end
  return string.format(
    "%02X-%02X-%02X-%02X-%02X-%02X",
    digest:byte(1),
    digest:byte(2),
    digest:byte(3),
    digest:byte(4),
    digest:byte(5),
    digest:byte(6)
  )
end

-- Base64url (RFC 4648 §5, no padding)
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"

function M.b64url_encode(s)
  local res, i = {}, 1
  while i <= #s do
    local b1, b2, b3 = s:byte(i), s:byte(i + 1) or 0, s:byte(i + 2) or 0
    local n = b1 * 65536 + b2 * 256 + b3
    res[#res + 1] = B64:sub(math.floor(n / 262144) + 1, math.floor(n / 262144) + 1)
    res[#res + 1] = B64:sub(math.floor(n / 4096) % 64 + 1, math.floor(n / 4096) % 64 + 1)
    if i + 1 <= #s then
      res[#res + 1] = B64:sub(math.floor(n / 64) % 64 + 1, math.floor(n / 64) % 64 + 1)
    end
    if i + 2 <= #s then
      res[#res + 1] = B64:sub(n % 64 + 1, n % 64 + 1)
    end
    i = i + 3
  end
  return table.concat(res)
end

local B64_DEC = {}
for i = 1, #B64 do
  B64_DEC[B64:sub(i, i)] = i - 1
end

function M.b64url_decode(s)
  local res, i = {}, 1
  while i <= #s do
    local v0 = B64_DEC[s:sub(i, i)] or 0
    local v1 = B64_DEC[s:sub(i + 1, i + 1)] or 0
    local v2 = B64_DEC[s:sub(i + 2, i + 2)]
    local v3 = B64_DEC[s:sub(i + 3, i + 3)]
    local n = v0 * 262144 + v1 * 4096
    res[#res + 1] = string.char(math.floor(n / 65536) % 256)
    if v2 then
      n = n + v2 * 64
      res[#res + 1] = string.char(math.floor(n / 256) % 256)
    end
    if v3 then
      res[#res + 1] = string.char((n + v3) % 256)
    end
    i = i + 4
  end
  return table.concat(res)
end

return M
