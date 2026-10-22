CREATE TABLE IF NOT EXISTS orders (
    id BIGSERIAL PRIMARY KEY,
    order_ref VARCHAR(64) NOT NULL UNIQUE,
    status VARCHAR(20) NOT NULL CHECK (status IN ('pending', 'in_transit', 'delivered')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

GRANT SELECT, INSERT ON TABLE orders TO andeslog_app;
GRANT USAGE, SELECT ON SEQUENCE orders_id_seq TO andeslog_app;
