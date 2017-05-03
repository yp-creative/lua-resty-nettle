require "resty.nettle.library"
require "resty.nettle.types.rsa"
require "resty.nettle.types.md5"
require "resty.nettle.types.sha1"
require "resty.nettle.types.sha2"

local ffi          = require "ffi"
local ffi_gc       = ffi.gc
local ffi_new      = ffi.new
local ffi_cdef     = ffi.cdef
local ffi_typeof   = ffi.typeof
local ffi_str      = ffi.string
local error        = error
local assert       = assert
local rawget       = rawget
local setmetatable = setmetatable
local mpz          = require "resty.nettle.mpz"
local buffer       = require "resty.nettle.buffer"
local yarrow       = require "resty.nettle.yarrow"
local knuth        = require "resty.nettle.knuth-lfib"
local hogweed      = require "resty.nettle.hogweed"

ffi_cdef[[
void nettle_rsa_public_key_init(struct rsa_public_key *key);
void nettle_rsa_public_key_clear(struct rsa_public_key *key);
int  nettle_rsa_public_key_prepare(struct rsa_public_key *key);
void nettle_rsa_private_key_init(struct rsa_private_key *key);
void nettle_rsa_private_key_clear(struct rsa_private_key *key);
int  nettle_rsa_private_key_prepare(struct rsa_private_key *key);
int  nettle_rsa_md5_sign(const struct rsa_private_key *key, struct md5_ctx *hash, mpz_t signature);
int  nettle_rsa_md5_verify(const struct rsa_public_key *key, struct md5_ctx *hash, const mpz_t signature);
int  nettle_rsa_sha1_sign(const struct rsa_private_key *key, struct sha1_ctx *hash, mpz_t signature);
int  nettle_rsa_sha1_verify(const struct rsa_public_key *key, struct sha1_ctx *hash, const mpz_t signature);
int  nettle_rsa_sha256_sign(const struct rsa_private_key *key, struct sha256_ctx *hash, mpz_t signature);
int  nettle_rsa_sha256_verify(const struct rsa_public_key *key, struct sha256_ctx *hash, const mpz_t signature);
int  nettle_rsa_sha512_sign(const struct rsa_private_key *key, struct sha512_ctx *hash, mpz_t signature);
int  nettle_rsa_sha512_verify(const struct rsa_public_key *key, struct sha512_ctx *hash, const mpz_t signature);
int  nettle_rsa_md5_sign_digest(const struct rsa_private_key *key, const uint8_t *digest, mpz_t s);
int  nettle_rsa_md5_verify_digest(const struct rsa_public_key *key, const uint8_t *digest, const mpz_t signature);
int  nettle_rsa_sha1_sign_digest(const struct rsa_private_key *key, const uint8_t *digest, mpz_t s);
int  nettle_rsa_sha1_verify_digest(const struct rsa_public_key *key, const uint8_t *digest, const mpz_t signature);
int  nettle_rsa_sha256_sign_digest(const struct rsa_private_key *key, const uint8_t *digest, mpz_t s);
int  nettle_rsa_sha256_verify_digest(const struct rsa_public_key *key, const uint8_t *digest, const mpz_t signature);
int  nettle_rsa_pss_sha256_verify_digest(const struct rsa_public_key *key, size_t salt_length, const uint8_t *digest, const mpz_t signature);
int  nettle_rsa_pss_sha384_verify_digest(const struct rsa_public_key *key, size_t salt_length, const uint8_t *digest, const mpz_t signature);
int  nettle_rsa_sha512_sign_digest(const struct rsa_private_key *key, const uint8_t *digest, mpz_t s);
int  nettle_rsa_sha512_verify_digest(const struct rsa_public_key *key, const uint8_t *digest, const mpz_t signature);
int  nettle_rsa_pss_sha512_verify_digest(const struct rsa_public_key *key, size_t salt_length, const uint8_t *digest, const mpz_t signature);
int  nettle_rsa_pkcs1_sign(const struct rsa_private_key *key, size_t length, const uint8_t *digest_info, mpz_t s);
int  nettle_rsa_pkcs1_verify(const struct rsa_public_key *key, size_t length, const uint8_t *digest_info, const mpz_t signature);
int  nettle_rsa_encrypt(const struct rsa_public_key *key, void *random_ctx, nettle_random_func *random, size_t length, const uint8_t *cleartext, mpz_t cipher);
int  nettle_rsa_decrypt(const struct rsa_private_key *key, size_t *length, uint8_t *cleartext, const mpz_t ciphertext);
void nettle_rsa_compute_root(const struct rsa_private_key *key, mpz_t x, const mpz_t m);
int  nettle_rsa_generate_keypair(struct rsa_public_key *pub, struct rsa_private_key *key, void *random_ctx, nettle_random_func *random, void *progress_ctx, nettle_progress_func *progress, unsigned n_size, unsigned e_size);
int  nettle_rsa_keypair_to_sexp(struct nettle_buffer *buffer, const char *algorithm_name, const struct rsa_public_key *pub, const struct rsa_private_key *priv);
int  nettle_rsa_keypair_from_sexp(struct rsa_public_key *pub, struct rsa_private_key *priv, unsigned limit, size_t length, const uint8_t *expr);
int  nettle_rsa_keypair_from_der(struct rsa_public_key *pub, struct rsa_private_key *priv, unsigned limit, size_t length, const uint8_t *data);
]]
local size = ffi_new "size_t[1]"
local buf  = ffi_typeof "uint8_t[?]"
local pub  = ffi_typeof "RSA_PUBLIC_KEY[1]"
local pri  = ffi_typeof "RSA_PRIVATE_KEY[1]"
local sig  = mpz.new()

local public = {}
public.__index = public

function public.new(n, e, base)
    local context = ffi_gc(ffi_new(pub), hogweed.nettle_rsa_public_key_clear)
    hogweed.nettle_rsa_public_key_init(context[0])
    if e then
        mpz.set(context[0].e, e, base)
    end
    if n then
        mpz.set(context[0].n, n, base)
    end
    assert(hogweed.nettle_rsa_public_key_prepare(context) == 1)
    return setmetatable({ context = context }, public)
end

function public:clear()
    hogweed.nettle_rsa_public_key_clear(self.context)
end

function public:e(base)
    return mpz.string(self.context[0].e, base)
end

function public:n(base)
    return mpz.string(self.context[0].n, base)
end

local private = {}
private.__index = private

function private.new(d, p, q, a, b, c, base)
    local context = ffi_gc(ffi_new(pri), hogweed.nettle_rsa_private_key_clear)
    hogweed.nettle_rsa_private_key_init(context)
    if d then
        mpz.set(context[0].d, d, base)
    end
    if p then
        mpz.set(context[0].p, p, base)
    end
    if q then
        mpz.set(context[0].q, q, base)
    end
    if a then
        mpz.set(context[0].a, a, base)
    end
    if b then
        mpz.set(context[0].b, b, base)
    end
    if c then
        mpz.set(context[0].c, c, base)
    end
    assert(hogweed.nettle_rsa_private_key_prepare(context) == 1)
    return setmetatable({ context = context }, private)
end

function private:d(base)
    return mpz.string(self.context[0].d, base)
end

function private:p(base)
    return mpz.string(self.context[0].p, base)
end

function private:q(base)
    return mpz.string(self.context[0].q, base)
end

function private:a(base)
    return mpz.string(self.context[0].a, base)
end

function private:b(base)
    return mpz.string(self.context[0].b, base)
end

function private:c(base)
    return mpz.string(self.context[0].c, base)
end

function private:clear()
    hogweed.nettle_rsa_private_key_clear(self.context)
end

local keypair = {}

function keypair:__index(n)
    if n == "sexp" then
        local b = buffer.new()
        hogweed.nettle_rsa_keypair_to_sexp(b, nil, self.public.context, self.private.context)
        return ffi_str(b.contents, b.size)
    else
        return rawget(keypair, n)
    end
end

function keypair.new(n, e, r, p, seed)
    n = n or 4096
    e = e or 65537
    local rf, rc
    if r == "knuth-lfib" or r == "knuth" then
        rc = knuth.context(seed)
        rf = knuth.func
    else
        rc = yarrow.context(seed or knuth.new():random(32))
        rf = yarrow.func
    end
    local pux = public.new()
    local prx = private.new()
    mpz.set(pux.context[0].e, e)
    assert(hogweed.nettle_rsa_generate_keypair(pux.context, prx.context, rc, rf, nil, p, n, 0) == 1)
    return setmetatable({
        public  = pux,
        private = prx
    }, keypair)
end

function keypair.der(data)
    local pux = public.new()
    local prx = private.new()
    assert(hogweed.nettle_rsa_keypair_from_der(pux.context, prx.context, 0, #data, data) == 1)
    return setmetatable({
        public  = pux,
        private = prx
    }, keypair)
end

local rsa = { keypair = keypair, key = { public = public, private = private } }
rsa.__index = rsa

function rsa.new(pub, pri)
    if not pub and not pri then
        local kp = keypair.new()
        pub = kp.public
        pri = kp.private
    end
    return setmetatable({ public = pub, private = pri }, rsa)
end

function rsa:encrypt(plain, r, seed)
    local encrypted = mpz.new()
    local rf, rc
    if r == "knuth-lfib" or r == "knuth" then
        rc = knuth.context(seed)
        rf = knuth.func
    else
        rc = yarrow.context(seed or knuth.new():random(32))
        rf = yarrow.func
    end
    local ok = hogweed.nettle_rsa_encrypt(self.public.context, rc, rf, #plain, plain, encrypted)
    if ok == 1 then
        return mpz.string(encrypted)
    end
    return nil
end

function rsa:decrypt(encrypted)
    local ct = mpz.new(encrypted)
    local sz = self.private.context[0].size
    local s = ffi_new(size)
    local b = ffi_new(buf, sz)
    s[0] = sz
    local ok = hogweed.nettle_rsa_decrypt(self.private.context, s, b, ct)
    if ok == 1 then
        return ffi_str(b, s[0])
    end
    return nil
end

function rsa:sign(digest, base)
    local l, ok = #digest, nil
    if l == 16 then
        ok = hogweed.nettle_rsa_md5_sign_digest(self.private.context, digest, sig)
    elseif l == 20 then
        ok = hogweed.nettle_rsa_sha1_sign_digest(self.private.context, digest, sig)
    elseif l == 32 then
        ok = hogweed.nettle_rsa_sha256_sign_digest(self.private.context, digest, sig)
    elseif l == 64 then
        ok = hogweed.nettle_rsa_sha512_sign_digest(self.private.context, digest, sig)
    else
        error("Supported digests are MD5, SHA1, SHA256, and SHA512")
    end
    if ok == 1 then
        return mpz.string(sig, base)
    end
    return nil
end

function rsa:verify(digest, signature, base)
    local l, ok = #digest, nil
    if l == 16 then
        ok = hogweed.nettle_rsa_md5_verify_digest(self.public.context, digest, mpz.new(signature, base))
    elseif l == 20 then
        ok = hogweed.nettle_rsa_sha1_verify_digest(self.public.context, digest, mpz.new(signature, base))
    elseif l == 32 then
        ok = hogweed.nettle_rsa_sha256_verify_digest(self.public.context, digest, mpz.new(signature, base))
    elseif l == 64 then
        ok = hogweed.nettle_rsa_sha512_verify_digest(self.public.context, digest, mpz.new(signature, base))
    else
        error("Supported digests are MD5, SHA1, SHA256, and SHA512")
    end
    return ok == 1
end

function rsa:verify_pss(salt_length, digest, signature, base)
    local l, ok = #digest, nil
    if l == 32 then
        ok = hogweed.nettle_rsa_pss_sha256_verify_digest(self.public.context, salt_length, digest, mpz.new(signature, base))
    elseif l == 48 then
        ok = hogweed.nettle_rsa_pss_sha384_verify_digest(self.public.context, salt_length, digest, mpz.new(signature, base))
    elseif l == 64 then
        ok = hogweed.nettle_rsa_pss_sha512_verify_digest(self.public.context, salt_length, digest, mpz.new(signature, base))
    else
        error("Supported digests are SHA256, SHA384, and SHA512")
    end
    return ok == 1
end

return rsa
