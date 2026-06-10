-- 02_geo.sql — geography & i18n reference data + tenant addresses.
-- Mostly GLOBAL reference tables (not tenant-scoped); addresses are tenant-scoped.
-- Ends by wiring identity.tenants' currency/locale defaults to geo (deferred FKs).

CREATE TABLE geo.countries (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    iso2        char(2) NOT NULL,
    iso3        char(3) NOT NULL,
    name        text NOT NULL,
    phone_code  text,
    continent   text,
    CONSTRAINT countries_iso2_key UNIQUE (iso2),
    CONSTRAINT countries_iso3_key UNIQUE (iso3)
);

CREATE TABLE geo.regions (
    id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    country_id bigint NOT NULL REFERENCES geo.countries(id),
    code       text,
    name       text NOT NULL
);
CREATE INDEX ON geo.regions (country_id);

CREATE TABLE geo.cities (
    id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    region_id  bigint REFERENCES geo.regions(id),
    country_id bigint NOT NULL REFERENCES geo.countries(id),
    name       text NOT NULL,
    latitude   numeric(9,6),
    longitude  numeric(9,6)
);
CREATE INDEX ON geo.cities (region_id);
CREATE INDEX ON geo.cities (country_id);

-- currencies: PK is id (per convention) but the FK target used everywhere is `code`.
CREATE TABLE geo.currencies (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code          char(3) NOT NULL,
    name          text NOT NULL,
    symbol        text,
    minor_unit    smallint NOT NULL DEFAULT 2 CHECK (minor_unit >= 0),
    CONSTRAINT currencies_code_key UNIQUE (code)
);

CREATE TABLE geo.exchange_rates (
    id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    base_code  char(3) NOT NULL REFERENCES geo.currencies(code),
    quote_code char(3) NOT NULL REFERENCES geo.currencies(code),
    rate       numeric(18,8) NOT NULL CHECK (rate > 0),
    as_of      date NOT NULL,
    CONSTRAINT exchange_rates_uq UNIQUE (base_code, quote_code, as_of)
);
CREATE INDEX ON geo.exchange_rates (as_of);

CREATE TABLE geo.locales (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code        char(5) NOT NULL,
    name        text NOT NULL,
    native_name text,
    CONSTRAINT locales_code_key UNIQUE (code)
);

CREATE TABLE geo.timezones (
    id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name               text NOT NULL,
    utc_offset_minutes integer NOT NULL,
    CONSTRAINT timezones_name_key UNIQUE (name)
);

-- addresses: tenant-scoped; optional owner user. One default per user via partial unique.
CREATE TABLE geo.addresses (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id   bigint NOT NULL REFERENCES identity.tenants(id),
    user_id     bigint REFERENCES identity.users(id) ON DELETE SET NULL,
    label       text,
    line1       text NOT NULL,
    line2       text,
    city        text,
    region_id   bigint REFERENCES geo.regions(id),
    country_id  bigint NOT NULL REFERENCES geo.countries(id),
    postal_code text,
    latitude    numeric(9,6),
    longitude   numeric(9,6),
    is_default  boolean NOT NULL DEFAULT false,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON geo.addresses (tenant_id);
CREATE INDEX ON geo.addresses (user_id);
CREATE INDEX ON geo.addresses (country_id);
CREATE UNIQUE INDEX addresses_one_default_per_user ON geo.addresses (user_id) WHERE is_default;

CREATE TABLE geo.address_validations (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id    bigint NOT NULL REFERENCES identity.tenants(id),
    address_id   bigint NOT NULL REFERENCES geo.addresses(id) ON DELETE CASCADE,
    provider     text NOT NULL,
    is_valid     boolean NOT NULL,
    response     jsonb,
    validated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON geo.address_validations (address_id);

CREATE TABLE geo.postal_zones (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    country_id  bigint NOT NULL REFERENCES geo.countries(id),
    code        text NOT NULL,
    name        text NOT NULL,
    CONSTRAINT postal_zones_uq UNIQUE (country_id, code)
);

-- --- deferred FKs: wire identity defaults to geo now that geo exists ---------
ALTER TABLE identity.tenants
    ADD CONSTRAINT tenants_currency_fk
    FOREIGN KEY (default_currency_code) REFERENCES geo.currencies(code);
ALTER TABLE identity.tenants
    ADD CONSTRAINT tenants_locale_fk
    FOREIGN KEY (default_locale) REFERENCES geo.locales(code);
ALTER TABLE identity.users
    ADD CONSTRAINT users_locale_fk
    FOREIGN KEY (locale) REFERENCES geo.locales(code);

-- --- comments ----------------------------------------------------------------
COMMENT ON TABLE geo.countries IS 'ISO-3166 country reference. Global, shared by all tenants.';
COMMENT ON TABLE geo.currencies IS 'ISO-4217 currencies. The code column (e.g. USD) is the FK target used by all monetary tables.';
COMMENT ON TABLE geo.exchange_rates IS 'Daily FX rates between currency pairs, used to normalize multi-currency revenue.';
COMMENT ON TABLE geo.addresses IS 'Postal addresses owned by a tenant and optionally a user. At most one default address per user.';
COMMENT ON COLUMN geo.currencies.minor_unit IS 'Number of decimal places (2 for USD, 0 for JPY).';
