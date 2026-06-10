-- 03_catalog.sql — products, variants, categories, brands, attributes, media.
-- The product master for the platform. Every table is tenant-scoped. Cross-schema
-- FKs target identity.tenants(id) and identity.users(id) only (product_reviews,
-- review_votes). Loads after 00-02. See CONVENTIONS.md and SCHEMA-MAP.md.
--
-- Soft-deletable entities (deleted_at): brands, products, product_variants,
-- categories, collections. Fact-ish/immutable junctions and the closure table
-- are not soft-deleted.

-- ===========================================================================
-- brands — manufacturer/brand records products belong to.
-- ===========================================================================
CREATE TABLE catalog.brands (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id   bigint NOT NULL REFERENCES identity.tenants(id),
    name        text NOT NULL,
    slug        text NOT NULL,
    description text,
    logo_url    text,
    website_url text,
    is_active   boolean NOT NULL DEFAULT true,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    deleted_at  timestamptz,
    CONSTRAINT brands_tenant_slug_uq UNIQUE (tenant_id, slug)
);
CREATE INDEX ON catalog.brands (tenant_id);

-- ===========================================================================
-- categories — hierarchical product taxonomy. parent_id is a self-FK; the
-- transitive closure is materialized separately in category_closure.
-- ===========================================================================
CREATE TABLE catalog.categories (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id   bigint NOT NULL REFERENCES identity.tenants(id),
    parent_id   bigint REFERENCES catalog.categories(id) ON DELETE SET NULL,
    name        text NOT NULL,
    slug        text NOT NULL,
    description text,
    position    integer NOT NULL DEFAULT 0,
    is_active   boolean NOT NULL DEFAULT true,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    deleted_at  timestamptz,
    CONSTRAINT categories_tenant_slug_uq UNIQUE (tenant_id, slug),
    CONSTRAINT categories_not_self_parent_ck CHECK (parent_id IS NULL OR parent_id <> id)
);
CREATE INDEX ON catalog.categories (tenant_id);
CREATE INDEX ON catalog.categories (parent_id);

-- ===========================================================================
-- category_closure — ancestor/descendant pairs with depth, so subtree queries
-- ("everything under Electronics") are a single join. depth 0 = self-row.
-- ===========================================================================
CREATE TABLE catalog.category_closure (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id     bigint NOT NULL REFERENCES identity.tenants(id),
    ancestor_id   bigint NOT NULL REFERENCES catalog.categories(id) ON DELETE CASCADE,
    descendant_id bigint NOT NULL REFERENCES catalog.categories(id) ON DELETE CASCADE,
    depth         integer NOT NULL CHECK (depth >= 0),
    created_at    timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT category_closure_uq UNIQUE (ancestor_id, descendant_id)
);
CREATE INDEX ON catalog.category_closure (tenant_id);
CREATE INDEX ON catalog.category_closure (ancestor_id);
CREATE INDEX ON catalog.category_closure (descendant_id);

-- ===========================================================================
-- products — the product master. public_id is the opaque external identifier.
-- ===========================================================================
CREATE TABLE catalog.products (
    id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    public_id        uuid NOT NULL DEFAULT gen_random_uuid(),
    tenant_id        bigint NOT NULL REFERENCES identity.tenants(id),
    brand_id         bigint REFERENCES catalog.brands(id) ON DELETE SET NULL,
    primary_category_id bigint REFERENCES catalog.categories(id) ON DELETE SET NULL,
    name             text NOT NULL,
    slug             text NOT NULL,
    description      text,
    status           catalog.product_status NOT NULL DEFAULT 'draft',
    is_visible       boolean NOT NULL DEFAULT true,
    published_at     timestamptz,
    seo_title        text,
    seo_description  text,
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now(),
    deleted_at       timestamptz,
    CONSTRAINT products_public_id_key UNIQUE (public_id),
    CONSTRAINT products_tenant_slug_uq UNIQUE (tenant_id, slug)
);
CREATE INDEX ON catalog.products (tenant_id);
CREATE INDEX ON catalog.products (brand_id);
CREATE INDEX ON catalog.products (primary_category_id);
CREATE INDEX products_tenant_status_idx ON catalog.products (tenant_id, status);

-- ===========================================================================
-- product_variants — the actual sellable SKUs under a product. sku is unique
-- per tenant. price_amount is a list/reference price; authoritative prices live
-- in the pricing module.
-- ===========================================================================
CREATE TABLE catalog.product_variants (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    public_id     uuid NOT NULL DEFAULT gen_random_uuid(),
    tenant_id     bigint NOT NULL REFERENCES identity.tenants(id),
    product_id    bigint NOT NULL REFERENCES catalog.products(id) ON DELETE CASCADE,
    sku           text NOT NULL,
    barcode       text,
    name          text,
    position      integer NOT NULL DEFAULT 0,
    price_amount  numeric(14,4) CHECK (price_amount >= 0),
    currency_code char(3) REFERENCES geo.currencies(code),
    weight_grams  numeric(14,4) CHECK (weight_grams >= 0),
    is_default    boolean NOT NULL DEFAULT false,
    is_active     boolean NOT NULL DEFAULT true,
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),
    deleted_at    timestamptz,
    CONSTRAINT product_variants_public_id_key UNIQUE (public_id),
    CONSTRAINT product_variants_tenant_sku_uq UNIQUE (tenant_id, sku),
    CONSTRAINT product_variants_price_currency_ck
        CHECK (price_amount IS NULL OR currency_code IS NOT NULL)
);
CREATE INDEX ON catalog.product_variants (tenant_id);
CREATE INDEX ON catalog.product_variants (product_id);
CREATE INDEX ON catalog.product_variants (currency_code);
CREATE UNIQUE INDEX product_variants_one_default_idx
    ON catalog.product_variants (product_id) WHERE is_default;

-- ===========================================================================
-- product_categories — junction products×categories (a product can sit in many
-- categories beyond its primary one).
-- ===========================================================================
CREATE TABLE catalog.product_categories (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id   bigint NOT NULL REFERENCES identity.tenants(id),
    product_id  bigint NOT NULL REFERENCES catalog.products(id) ON DELETE CASCADE,
    category_id bigint NOT NULL REFERENCES catalog.categories(id) ON DELETE CASCADE,
    position    integer NOT NULL DEFAULT 0,
    created_at  timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT product_categories_uq UNIQUE (product_id, category_id)
);
CREATE INDEX ON catalog.product_categories (tenant_id);
CREATE INDEX ON catalog.product_categories (category_id);

-- ===========================================================================
-- attributes — definitions of product/variant attributes (e.g. Color, Size).
-- kind drives how attribute_values are interpreted.
-- ===========================================================================
CREATE TABLE catalog.attributes (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id    bigint NOT NULL REFERENCES identity.tenants(id),
    code         text NOT NULL,
    name         text NOT NULL,
    kind         catalog.attribute_kind NOT NULL DEFAULT 'text',
    is_variant_defining boolean NOT NULL DEFAULT false,
    is_filterable boolean NOT NULL DEFAULT false,
    unit         text,
    position     integer NOT NULL DEFAULT 0,
    created_at   timestamptz NOT NULL DEFAULT now(),
    updated_at   timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT attributes_tenant_code_uq UNIQUE (tenant_id, code)
);
CREATE INDEX ON catalog.attributes (tenant_id);

-- ===========================================================================
-- attribute_values — allowed values for enum-kind attributes.
-- ===========================================================================
CREATE TABLE catalog.attribute_values (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id    bigint NOT NULL REFERENCES identity.tenants(id),
    attribute_id bigint NOT NULL REFERENCES catalog.attributes(id) ON DELETE CASCADE,
    value        text NOT NULL,
    label        text,
    position     integer NOT NULL DEFAULT 0,
    created_at   timestamptz NOT NULL DEFAULT now(),
    updated_at   timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT attribute_values_uq UNIQUE (attribute_id, value)
);
CREATE INDEX ON catalog.attribute_values (tenant_id);
CREATE INDEX ON catalog.attribute_values (attribute_id);

-- ===========================================================================
-- variant_attribute_values — junction variants×attribute_values, defining the
-- attribute combination that makes a variant unique (Color=Red, Size=L).
-- ===========================================================================
CREATE TABLE catalog.variant_attribute_values (
    id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id          bigint NOT NULL REFERENCES identity.tenants(id),
    variant_id         bigint NOT NULL REFERENCES catalog.product_variants(id) ON DELETE CASCADE,
    attribute_id       bigint NOT NULL REFERENCES catalog.attributes(id) ON DELETE CASCADE,
    attribute_value_id bigint REFERENCES catalog.attribute_values(id) ON DELETE CASCADE,
    value_text         text,
    created_at         timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT variant_attribute_values_uq UNIQUE (variant_id, attribute_id)
);
CREATE INDEX ON catalog.variant_attribute_values (tenant_id);
CREATE INDEX ON catalog.variant_attribute_values (attribute_id);
CREATE INDEX ON catalog.variant_attribute_values (attribute_value_id);

-- ===========================================================================
-- product_media — images, video, and other media attached to products and
-- optionally a specific variant. kind is the media classification.
-- ===========================================================================
CREATE TABLE catalog.product_media (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id   bigint NOT NULL REFERENCES identity.tenants(id),
    product_id  bigint NOT NULL REFERENCES catalog.products(id) ON DELETE CASCADE,
    variant_id  bigint REFERENCES catalog.product_variants(id) ON DELETE CASCADE,
    kind        catalog.media_kind NOT NULL DEFAULT 'image',
    url         text NOT NULL,
    alt_text    text,
    position    integer NOT NULL DEFAULT 0,
    is_primary  boolean NOT NULL DEFAULT false,
    width_px    integer CHECK (width_px IS NULL OR width_px > 0),
    height_px   integer CHECK (height_px IS NULL OR height_px > 0),
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON catalog.product_media (tenant_id);
CREATE INDEX ON catalog.product_media (product_id);
CREATE INDEX ON catalog.product_media (variant_id);
CREATE UNIQUE INDEX product_media_one_primary_idx
    ON catalog.product_media (product_id) WHERE is_primary;

-- ===========================================================================
-- collections — merchandising groupings (e.g. "Summer Sale", "New Arrivals").
-- ===========================================================================
CREATE TABLE catalog.collections (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id    bigint NOT NULL REFERENCES identity.tenants(id),
    name         text NOT NULL,
    slug         text NOT NULL,
    description  text,
    is_automated boolean NOT NULL DEFAULT false,
    rules        jsonb,
    starts_at    timestamptz,
    ends_at      timestamptz,
    created_at   timestamptz NOT NULL DEFAULT now(),
    updated_at   timestamptz NOT NULL DEFAULT now(),
    deleted_at   timestamptz,
    CONSTRAINT collections_tenant_slug_uq UNIQUE (tenant_id, slug),
    CONSTRAINT collections_window_ck CHECK (ends_at IS NULL OR starts_at IS NULL OR ends_at > starts_at)
);
CREATE INDEX ON catalog.collections (tenant_id);

-- ===========================================================================
-- collection_products — junction collections×products.
-- ===========================================================================
CREATE TABLE catalog.collection_products (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id     bigint NOT NULL REFERENCES identity.tenants(id),
    collection_id bigint NOT NULL REFERENCES catalog.collections(id) ON DELETE CASCADE,
    product_id    bigint NOT NULL REFERENCES catalog.products(id) ON DELETE CASCADE,
    position      integer NOT NULL DEFAULT 0,
    created_at    timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT collection_products_uq UNIQUE (collection_id, product_id)
);
CREATE INDEX ON catalog.collection_products (tenant_id);
CREATE INDEX ON catalog.collection_products (product_id);

-- ===========================================================================
-- tags — free-form labels applied to products.
-- ===========================================================================
CREATE TABLE catalog.tags (
    id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id  bigint NOT NULL REFERENCES identity.tenants(id),
    name       text NOT NULL,
    slug       text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT tags_tenant_slug_uq UNIQUE (tenant_id, slug)
);
CREATE INDEX ON catalog.tags (tenant_id);

-- ===========================================================================
-- product_tags — junction products×tags.
-- ===========================================================================
CREATE TABLE catalog.product_tags (
    id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id  bigint NOT NULL REFERENCES identity.tenants(id),
    product_id bigint NOT NULL REFERENCES catalog.products(id) ON DELETE CASCADE,
    tag_id     bigint NOT NULL REFERENCES catalog.tags(id) ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT product_tags_uq UNIQUE (product_id, tag_id)
);
CREATE INDEX ON catalog.product_tags (tenant_id);
CREATE INDEX ON catalog.product_tags (tag_id);

-- ===========================================================================
-- product_reviews — customer reviews of products. rating is 1-5 stars. user_id
-- is the reviewing identity.users row; nullable for anonymized/imported reviews.
-- ===========================================================================
CREATE TABLE catalog.product_reviews (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id     bigint NOT NULL REFERENCES identity.tenants(id),
    product_id    bigint NOT NULL REFERENCES catalog.products(id) ON DELETE CASCADE,
    user_id       bigint REFERENCES identity.users(id) ON DELETE SET NULL,
    rating        integer NOT NULL CHECK (rating BETWEEN 1 AND 5),
    title         text,
    body          text,
    is_verified_purchase boolean NOT NULL DEFAULT false,
    is_approved   boolean NOT NULL DEFAULT false,
    helpful_count integer NOT NULL DEFAULT 0 CHECK (helpful_count >= 0),
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT product_reviews_one_per_user_uq UNIQUE (product_id, user_id)
);
CREATE INDEX ON catalog.product_reviews (tenant_id);
CREATE INDEX ON catalog.product_reviews (product_id);
CREATE INDEX ON catalog.product_reviews (user_id);
CREATE INDEX product_reviews_approved_idx
    ON catalog.product_reviews (product_id) WHERE is_approved;

-- ===========================================================================
-- review_votes — helpfulness votes cast by users on a review.
-- ===========================================================================
CREATE TABLE catalog.review_votes (
    id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id  bigint NOT NULL REFERENCES identity.tenants(id),
    review_id  bigint NOT NULL REFERENCES catalog.product_reviews(id) ON DELETE CASCADE,
    user_id    bigint NOT NULL REFERENCES identity.users(id) ON DELETE CASCADE,
    is_helpful boolean NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT review_votes_one_per_user_uq UNIQUE (review_id, user_id)
);
CREATE INDEX ON catalog.review_votes (tenant_id);
CREATE INDEX ON catalog.review_votes (user_id);

-- ===========================================================================
-- product_relations — directional cross-sell / upsell / related pairs between
-- two products. relation_kind classifies the link.
-- ===========================================================================
CREATE TABLE catalog.product_relations (
    id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id          bigint NOT NULL REFERENCES identity.tenants(id),
    product_id         bigint NOT NULL REFERENCES catalog.products(id) ON DELETE CASCADE,
    related_product_id bigint NOT NULL REFERENCES catalog.products(id) ON DELETE CASCADE,
    relation_kind      text NOT NULL DEFAULT 'related',
    position           integer NOT NULL DEFAULT 0,
    created_at         timestamptz NOT NULL DEFAULT now(),
    updated_at         timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT product_relations_uq UNIQUE (product_id, related_product_id, relation_kind),
    CONSTRAINT product_relations_not_self_ck CHECK (product_id <> related_product_id)
);
CREATE INDEX ON catalog.product_relations (tenant_id);
CREATE INDEX ON catalog.product_relations (product_id);
CREATE INDEX ON catalog.product_relations (related_product_id);

-- ===========================================================================
-- product_bundles — header for a bundle/kit sold as a single offering.
-- ===========================================================================
CREATE TABLE catalog.product_bundles (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id   bigint NOT NULL REFERENCES identity.tenants(id),
    product_id  bigint REFERENCES catalog.products(id) ON DELETE SET NULL,
    name        text NOT NULL,
    slug        text NOT NULL,
    description text,
    is_active   boolean NOT NULL DEFAULT true,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT product_bundles_tenant_slug_uq UNIQUE (tenant_id, slug)
);
CREATE INDEX ON catalog.product_bundles (tenant_id);
CREATE INDEX ON catalog.product_bundles (product_id);

-- ===========================================================================
-- bundle_items — the component variants (and quantities) that make up a bundle.
-- ===========================================================================
CREATE TABLE catalog.bundle_items (
    id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id  bigint NOT NULL REFERENCES identity.tenants(id),
    bundle_id  bigint NOT NULL REFERENCES catalog.product_bundles(id) ON DELETE CASCADE,
    variant_id bigint NOT NULL REFERENCES catalog.product_variants(id) ON DELETE RESTRICT,
    quantity   integer NOT NULL DEFAULT 1 CHECK (quantity > 0),
    position   integer NOT NULL DEFAULT 0,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT bundle_items_uq UNIQUE (bundle_id, variant_id)
);
CREATE INDEX ON catalog.bundle_items (tenant_id);
CREATE INDEX ON catalog.bundle_items (bundle_id);
CREATE INDEX ON catalog.bundle_items (variant_id);

-- --- comments (≈70% coverage; some tables intentionally left undocumented) ---
COMMENT ON TABLE catalog.brands IS 'Manufacturer/brand records that products are grouped under.';
COMMENT ON TABLE catalog.categories IS 'Hierarchical product taxonomy; parent_id is a self-reference to the parent category.';
COMMENT ON TABLE catalog.category_closure IS 'Transitive closure of the category tree (ancestor, descendant, depth) for fast subtree queries.';
COMMENT ON COLUMN catalog.category_closure.depth IS 'Number of edges between ancestor and descendant; 0 is the self-row.';
COMMENT ON TABLE catalog.products IS 'Product master records; public_id is the opaque external identifier exposed via API/URL.';
COMMENT ON TABLE catalog.product_variants IS 'Sellable SKUs of a product; sku is unique per tenant. Reference price only — authoritative pricing lives in the pricing schema.';
COMMENT ON COLUMN catalog.product_variants.is_default IS 'Exactly one variant per product may be the default (enforced by a partial unique index).';
COMMENT ON TABLE catalog.attributes IS 'Definitions of product/variant attributes (e.g. Color, Size); kind drives value interpretation.';
COMMENT ON COLUMN catalog.attributes.is_variant_defining IS 'True when this attribute differentiates variants (Color, Size) rather than being descriptive.';
COMMENT ON TABLE catalog.attribute_values IS 'Allowed values for enum-kind attributes.';
COMMENT ON TABLE catalog.variant_attribute_values IS 'Junction binding a variant to its attribute/value pairs (the combination that makes it unique).';
COMMENT ON TABLE catalog.product_media IS 'Images, video, and documents attached to a product and optionally a specific variant.';
COMMENT ON TABLE catalog.collections IS 'Merchandising groupings of products; may be manual or rule-driven (is_automated).';
COMMENT ON TABLE catalog.product_reviews IS 'Customer reviews of products, rated 1-5 stars; one review per user per product.';
COMMENT ON COLUMN catalog.product_reviews.is_verified_purchase IS 'True when the reviewer is known to have purchased the product.';
COMMENT ON TABLE catalog.product_relations IS 'Directional cross-sell/upsell/related links between two products.';
COMMENT ON TABLE catalog.product_bundles IS 'Header for a bundle/kit sold as a single offering, composed of variant components.';
COMMENT ON TABLE catalog.bundle_items IS 'Component variants and quantities that make up a product bundle.';
