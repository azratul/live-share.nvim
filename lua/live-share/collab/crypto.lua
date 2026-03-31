-- AES-256-GCM encryption via LuaJIT FFI → OpenSSL libcrypto.
-- Falls back to a no-op passthrough when FFI or OpenSSL is unavailable.
--
-- Frame layout (encrypted):  [ 12-byte nonce ][ ciphertext ][ 16-byte GCM tag ]
-- Key length: 32 bytes (AES-256).  Nonce: 12 random bytes per message.
local M = {}

local ffi_ok, ffi = pcall(require, "ffi")
if not ffi_ok then
  M.available = false
  return M
end

-- Try common library names across Linux, macOS, Windows
local lib
for _, name in ipairs({ "crypto", "libcrypto.so.3", "libcrypto.so.1.1", "libcrypto.dylib" }) do
  local ok, l = pcall(ffi.load, name)
  if ok then lib = l; break end
end

if not lib then
  M.available = false
  return M
end

pcall(ffi.cdef, [[
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
]])

M.available = true

local EVP_CTRL_GCM_SET_IVLEN = 0x9
local EVP_CTRL_GCM_GET_TAG   = 0x10
local EVP_CTRL_GCM_SET_TAG   = 0x11
local NONCE_LEN = 12
local TAG_LEN   = 16

function M.random_bytes(n)
  local buf = ffi.new("unsigned char[?]", n)
  lib.RAND_bytes(buf, n)
  return ffi.string(buf, n)
end

function M.generate_key()
  return M.random_bytes(32)
end

-- Returns ciphertext .. tag.
function M.encrypt(plaintext, key, nonce)
  local ctx  = lib.EVP_CIPHER_CTX_new()
  local out  = ffi.new("unsigned char[?]", #plaintext + TAG_LEN)
  local outl = ffi.new("int[1]")
  local tag  = ffi.new("unsigned char[?]", TAG_LEN)

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
  if #ciphertext_with_tag <= TAG_LEN then return nil end
  local ct_len = #ciphertext_with_tag - TAG_LEN

  local ctx  = lib.EVP_CIPHER_CTX_new()
  local out  = ffi.new("unsigned char[?]", ct_len + TAG_LEN)
  local outl = ffi.new("int[1]")
  local tag  = ffi.new("unsigned char[?]", TAG_LEN)
  ffi.copy(tag, ciphertext_with_tag:sub(ct_len + 1), TAG_LEN)

  lib.EVP_DecryptInit_ex(ctx, lib.EVP_aes_256_gcm(), nil, nil, nil)
  lib.EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_IVLEN, NONCE_LEN, nil)
  lib.EVP_DecryptInit_ex(ctx, nil, nil, key, nonce)
  lib.EVP_DecryptUpdate(ctx, out, outl, ciphertext_with_tag, ct_len)
  local pt_len = outl[0]
  lib.EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_TAG, TAG_LEN, tag)
  local ok = lib.EVP_DecryptFinal_ex(ctx, out + pt_len, outl)
  lib.EVP_CIPHER_CTX_free(ctx)

  if ok ~= 1 then return nil end
  return ffi.string(out, pt_len + outl[0])
end

-- Base64url (RFC 4648 §5, no padding)
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"

function M.b64url_encode(s)
  local res, i = {}, 1
  while i <= #s do
    local b1, b2, b3 = s:byte(i), s:byte(i+1) or 0, s:byte(i+2) or 0
    local n = b1*65536 + b2*256 + b3
    res[#res+1] = B64:sub(math.floor(n/262144)+1,   math.floor(n/262144)+1)
    res[#res+1] = B64:sub(math.floor(n/4096)%64+1,  math.floor(n/4096)%64+1)
    if i+1 <= #s then res[#res+1] = B64:sub(math.floor(n/64)%64+1, math.floor(n/64)%64+1) end
    if i+2 <= #s then res[#res+1] = B64:sub(n%64+1, n%64+1) end
    i = i + 3
  end
  return table.concat(res)
end

local B64_DEC = {}
for i = 1, #B64 do B64_DEC[B64:sub(i,i)] = i-1 end

function M.b64url_decode(s)
  local res, i = {}, 1
  while i <= #s do
    local v0 = B64_DEC[s:sub(i,   i  )] or 0
    local v1 = B64_DEC[s:sub(i+1, i+1)] or 0
    local v2 = B64_DEC[s:sub(i+2, i+2)]
    local v3 = B64_DEC[s:sub(i+3, i+3)]
    local n  = v0*262144 + v1*4096
    res[#res+1] = string.char(math.floor(n/65536) % 256)
    if v2 then
      n = n + v2*64
      res[#res+1] = string.char(math.floor(n/256) % 256)
    end
    if v3 then
      res[#res+1] = string.char((n + v3) % 256)
    end
    i = i + 4
  end
  return table.concat(res)
end

return M
