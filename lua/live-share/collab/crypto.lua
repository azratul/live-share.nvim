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

  // X25519 (OpenSSL 1.1.1+) — used for ephemeral ECDH at session start.
  typedef struct evp_pkey_st     EVP_PKEY;
  typedef struct evp_pkey_ctx_st EVP_PKEY_CTX;
  EVP_PKEY_CTX *EVP_PKEY_CTX_new_id(int id, void *e);
  void          EVP_PKEY_CTX_free(EVP_PKEY_CTX *ctx);
  int EVP_PKEY_keygen_init(EVP_PKEY_CTX *ctx);
  int EVP_PKEY_keygen(EVP_PKEY_CTX *ctx, EVP_PKEY **ppkey);
  int EVP_PKEY_get_raw_public_key(const EVP_PKEY *pkey, unsigned char *pub, size_t *len);
  int EVP_PKEY_get_raw_private_key(const EVP_PKEY *pkey, unsigned char *priv, size_t *len);
  EVP_PKEY *EVP_PKEY_new_raw_public_key(int type, void *e, const unsigned char *key, size_t keylen);
  EVP_PKEY *EVP_PKEY_new_raw_private_key(int type, void *e, const unsigned char *key, size_t keylen);
  void EVP_PKEY_free(EVP_PKEY *pkey);
  EVP_PKEY_CTX *EVP_PKEY_CTX_new(EVP_PKEY *pkey, void *e);
  int EVP_PKEY_derive_init(EVP_PKEY_CTX *ctx);
  int EVP_PKEY_derive_set_peer(EVP_PKEY_CTX *ctx, EVP_PKEY *peer);
  int EVP_PKEY_derive(EVP_PKEY_CTX *ctx, unsigned char *key, size_t *keylen);

  // HMAC (single-shot API, sufficient for HKDF and the dh_offer/dh_accept tag).
  unsigned char *HMAC(const EVP_MD *evp_md, const void *key, int key_len,
                      const unsigned char *d, size_t n,
                      unsigned char *md, unsigned int *md_len);
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
-- `aad` is optional Additional Authenticated Data: not encrypted, but bound
-- into the GCM tag so any tampering is detected on decrypt.  Pass nil for
-- v3-compatible behaviour (no AAD).
function M.encrypt(plaintext, key, nonce, aad)
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
  if aad and #aad > 0 then
    -- AAD must be fed before the plaintext; pass NULL output buffer.
    lib.EVP_EncryptUpdate(ctx, nil, outl, aad, #aad)
  end
  lib.EVP_EncryptUpdate(ctx, out, outl, plaintext, #plaintext)
  local ct_len = outl[0]
  lib.EVP_EncryptFinal_ex(ctx, out + ct_len, outl)
  ct_len = ct_len + outl[0]
  lib.EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_GET_TAG, TAG_LEN, tag)
  lib.EVP_CIPHER_CTX_free(ctx)

  return ffi.string(out, ct_len) .. ffi.string(tag, TAG_LEN)
end

-- Returns plaintext, or nil if authentication fails (wrong key, tampered
-- ciphertext, or AAD mismatch — the GCM tag verifies all three together).
function M.decrypt(ciphertext_with_tag, key, nonce, aad)
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
  if aad and #aad > 0 then
    lib.EVP_DecryptUpdate(ctx, nil, outl, aad, #aad)
  end
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

-- ── X25519 ECDH (OpenSSL 1.1.1+) ─────────────────────────────────────────────
--
-- Used by the v4 forward-secrecy handshake (`dh_offer`/`dh_accept`).  Each
-- peer pair generates a fresh ephemeral keypair at session start and derives
-- a shared 32-byte secret that is then fed into HKDF to produce a per-peer
-- AES-GCM subkey.  The URL-fragment master key never encrypts traffic
-- directly — it only acts as a PSK that authenticates the public keys via
-- HMAC, so a future compromise of the master key cannot decrypt recorded
-- ciphertext.

local NID_X25519 = 1034 -- OpenSSL constant; stable across 1.1.1+.

-- Returns priv (32 bytes), pub (32 bytes), or nil + error string.
function M.x25519_keypair()
  if not M.available then
    return nil, "openssl unavailable"
  end
  local pctx = lib.EVP_PKEY_CTX_new_id(NID_X25519, nil)
  if pctx == nil then
    return nil, "EVP_PKEY_CTX_new_id failed"
  end
  if lib.EVP_PKEY_keygen_init(pctx) ~= 1 then
    lib.EVP_PKEY_CTX_free(pctx)
    return nil, "EVP_PKEY_keygen_init failed"
  end
  local pkey_pp = ffi.new("EVP_PKEY*[1]")
  if lib.EVP_PKEY_keygen(pctx, pkey_pp) ~= 1 then
    lib.EVP_PKEY_CTX_free(pctx)
    return nil, "EVP_PKEY_keygen failed"
  end
  lib.EVP_PKEY_CTX_free(pctx)
  local pkey = pkey_pp[0]

  local priv_buf = ffi.new("unsigned char[?]", 32)
  local pub_buf = ffi.new("unsigned char[?]", 32)
  local len = ffi.new("size_t[1]", 32)
  local ok_priv = lib.EVP_PKEY_get_raw_private_key(pkey, priv_buf, len) == 1
  len[0] = 32
  local ok_pub = lib.EVP_PKEY_get_raw_public_key(pkey, pub_buf, len) == 1
  lib.EVP_PKEY_free(pkey)
  if not ok_priv or not ok_pub then
    return nil, "EVP_PKEY_get_raw_*_key failed"
  end
  return ffi.string(priv_buf, 32), ffi.string(pub_buf, 32)
end

-- Returns 32-byte shared secret, or nil + error string.
function M.x25519_shared(priv_bytes, peer_pub_bytes)
  if not M.available then
    return nil, "openssl unavailable"
  end
  if not priv_bytes or #priv_bytes ~= 32 or not peer_pub_bytes or #peer_pub_bytes ~= 32 then
    return nil, "expected 32-byte priv and pub"
  end
  local priv_pkey = lib.EVP_PKEY_new_raw_private_key(NID_X25519, nil, priv_bytes, 32)
  if priv_pkey == nil then
    return nil, "EVP_PKEY_new_raw_private_key failed"
  end
  local peer_pkey = lib.EVP_PKEY_new_raw_public_key(NID_X25519, nil, peer_pub_bytes, 32)
  if peer_pkey == nil then
    lib.EVP_PKEY_free(priv_pkey)
    return nil, "EVP_PKEY_new_raw_public_key failed"
  end
  local pctx = lib.EVP_PKEY_CTX_new(priv_pkey, nil)
  if pctx == nil then
    lib.EVP_PKEY_free(priv_pkey)
    lib.EVP_PKEY_free(peer_pkey)
    return nil, "EVP_PKEY_CTX_new failed"
  end
  if lib.EVP_PKEY_derive_init(pctx) ~= 1 or lib.EVP_PKEY_derive_set_peer(pctx, peer_pkey) ~= 1 then
    lib.EVP_PKEY_CTX_free(pctx)
    lib.EVP_PKEY_free(priv_pkey)
    lib.EVP_PKEY_free(peer_pkey)
    return nil, "derive setup failed"
  end
  local out = ffi.new("unsigned char[?]", 32)
  local outlen = ffi.new("size_t[1]", 32)
  local ok = lib.EVP_PKEY_derive(pctx, out, outlen) == 1
  lib.EVP_PKEY_CTX_free(pctx)
  lib.EVP_PKEY_free(priv_pkey)
  lib.EVP_PKEY_free(peer_pkey)
  if not ok then
    return nil, "EVP_PKEY_derive failed"
  end
  return ffi.string(out, tonumber(outlen[0]))
end

-- Probe X25519 availability once at module load — older OpenSSL builds
-- (< 1.1.1) lack the EVP_PKEY raw-key API.  Sessions falling back to
-- master-key encryption when this is false are flagged in host.lua.
M.x25519_available = (function()
  if not M.available then
    return false
  end
  local priv, _ = M.x25519_keypair()
  return priv ~= nil
end)()

-- ── HMAC-SHA256 ──────────────────────────────────────────────────────────────

function M.hmac_sha256(key, data)
  if not M.available then
    return nil
  end
  local out = ffi.new("unsigned char[32]")
  local outlen = ffi.new("unsigned int[1]", 32)
  local r = lib.HMAC(lib.EVP_sha256(), key, #key, data, #data, out, outlen)
  if r == nil then
    return nil
  end
  return ffi.string(out, 32)
end

-- ── HKDF-SHA256 (RFC 5869) ───────────────────────────────────────────────────
--
-- Implemented in terms of HMAC-SHA256 rather than EVP_KDF to keep the
-- function surface small and to avoid the OpenSSL 3.x EVP_KDF API split.
-- For 32-byte output (our only use case) the expand step needs a single
-- HMAC iteration.

local function hkdf_extract(salt, ikm)
  return M.hmac_sha256(salt, ikm)
end

local function hkdf_expand(prk, info, length)
  local out = {}
  local t = ""
  local i = 1
  while #table.concat(out) < length do
    t = M.hmac_sha256(prk, t .. (info or "") .. string.char(i))
    if not t then
      return nil
    end
    out[#out + 1] = t
    i = i + 1
  end
  return table.concat(out):sub(1, length)
end

function M.hkdf_sha256(ikm, salt, info, length)
  if not M.available or not ikm then
    return nil
  end
  if not salt or #salt == 0 then
    salt = string.rep("\0", 32)
  end
  local prk = hkdf_extract(salt, ikm)
  if not prk then
    return nil
  end
  return hkdf_expand(prk, info, length or 32)
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
