#!/bin/bash

# Minimal PostgreSQL startup script with full paths
DB_NAME="myapp"
DB_USER="appuser"
DB_PASSWORD="dbuser123"
DB_PORT="5000"

echo "Starting PostgreSQL setup..."

# Find PostgreSQL version and set paths
PG_VERSION=$(ls /usr/lib/postgresql/ | head -1)
PG_BIN="/usr/lib/postgresql/${PG_VERSION}/bin"

echo "Found PostgreSQL version: ${PG_VERSION}"

# Check if PostgreSQL is already running on the specified port
# NOTE: Do NOT exit here. We still want to ensure schema + seed exist.
POSTGRES_ALREADY_RUNNING="false"
if sudo -u postgres ${PG_BIN}/pg_isready -p ${DB_PORT} > /dev/null 2>&1; then
    POSTGRES_ALREADY_RUNNING="true"
    echo "PostgreSQL is already running on port ${DB_PORT}."
fi

# Also check if there's a PostgreSQL process running (in case pg_isready fails)
if [ "${POSTGRES_ALREADY_RUNNING}" != "true" ] && pgrep -f "postgres.*-p ${DB_PORT}" > /dev/null 2>&1; then
    echo "Found existing PostgreSQL process on port ${DB_PORT}"
    echo "Attempting to verify readiness..."
    if sudo -u postgres ${PG_BIN}/psql -p ${DB_PORT} -d postgres -c '\q' 2>/dev/null; then
        POSTGRES_ALREADY_RUNNING="true"
        echo "PostgreSQL process is responsive."
    fi
fi

# Initialize PostgreSQL data directory if it doesn't exist
if [ ! -f "/var/lib/postgresql/data/PG_VERSION" ]; then
    echo "Initializing PostgreSQL..."
    sudo -u postgres ${PG_BIN}/initdb -D /var/lib/postgresql/data
fi

# Start PostgreSQL server in background (only if not already running)
if [ "${POSTGRES_ALREADY_RUNNING}" != "true" ]; then
    echo "Starting PostgreSQL server..."
    sudo -u postgres ${PG_BIN}/postgres -D /var/lib/postgresql/data -p ${DB_PORT} &
    echo "Waiting for PostgreSQL to start..."
    sleep 5
else
    echo "Skipping postgres start (already running)."
fi

# Check if PostgreSQL is running
for i in {1..15}; do
    if sudo -u postgres ${PG_BIN}/pg_isready -p ${DB_PORT} > /dev/null 2>&1; then
        echo "PostgreSQL is ready!"
        break
    fi
    echo "Waiting... ($i/15)"
    sleep 2
done

# Create database and user
echo "Setting up database and user..."
sudo -u postgres ${PG_BIN}/createdb -p ${DB_PORT} ${DB_NAME} 2>/dev/null || echo "Database might already exist"

# Set up user and permissions with proper schema ownership
sudo -u postgres ${PG_BIN}/psql -p ${DB_PORT} -d postgres << EOF
-- Create user if doesn't exist
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '${DB_USER}') THEN
        CREATE ROLE ${DB_USER} WITH LOGIN PASSWORD '${DB_PASSWORD}';
    END IF;
    ALTER ROLE ${DB_USER} WITH PASSWORD '${DB_PASSWORD}';
END
\$\$;

-- Grant database-level permissions
GRANT ALL PRIVILEGES ON DATABASE ${DB_NAME} TO ${DB_USER};

-- Connect to the specific database for schema-level permissions
\c ${DB_NAME}

-- For PostgreSQL 15+, we need to handle public schema permissions differently
-- First, grant usage on public schema
GRANT USAGE ON SCHEMA public TO ${DB_USER};

-- Grant CREATE permission on public schema
GRANT CREATE ON SCHEMA public TO ${DB_USER};

-- Make the user owner of all future objects they create in public schema
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO ${DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO ${DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO ${DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TYPES TO ${DB_USER};

-- If you want the user to be able to create objects without restrictions,
-- you can make them the owner of the public schema (optional but effective)
-- ALTER SCHEMA public OWNER TO ${DB_USER};

-- Alternative: Grant all privileges on schema public to the user
GRANT ALL ON SCHEMA public TO ${DB_USER};

-- Ensure the user can work with any existing objects
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO ${DB_USER};
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO ${DB_USER};
GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public TO ${DB_USER};
EOF

# Additionally, connect to the specific database to ensure permissions
sudo -u postgres ${PG_BIN}/psql -p ${DB_PORT} -d ${DB_NAME} << EOF
-- Double-check permissions are set correctly in the target database
GRANT ALL ON SCHEMA public TO ${DB_USER};
GRANT CREATE ON SCHEMA public TO ${DB_USER};

-- Show current permissions for debugging
\dn+ public
EOF

# Save connection command to a file
echo "psql postgresql://${DB_USER}:${DB_PASSWORD}@localhost:${DB_PORT}/${DB_NAME}" > db_connection.txt
echo "Connection string saved to db_connection.txt"

# Save environment variables to a file
cat > db_visualizer/postgres.env << EOF
export POSTGRES_URL="postgresql://localhost:${DB_PORT}/${DB_NAME}"
export POSTGRES_USER="${DB_USER}"
export POSTGRES_PASSWORD="${DB_PASSWORD}"
export POSTGRES_DB="${DB_NAME}"
export POSTGRES_PORT="${DB_PORT}"
EOF

echo "PostgreSQL setup complete!"
echo "Database: ${DB_NAME}"
echo "User: ${DB_USER}"
echo "Port: ${DB_PORT}"
echo ""

echo "Environment variables saved to db_visualizer/postgres.env"
echo "To use with Node.js viewer, run: source db_visualizer/postgres.env"

echo "To connect to the database, use one of the following commands:"
echo "psql -h localhost -U ${DB_USER} -d ${DB_NAME} -p ${DB_PORT}"
echo "$(cat db_connection.txt)"
echo ""

echo "Applying resident directory schema + seed data (idempotent)..."

# IMPORTANT: Per container rule, always use db_connection.txt as the source of truth for connection.
PSQL_CMD="$(cat db_connection.txt)"

# --- Schema: admins ---
${PSQL_CMD} -v ON_ERROR_STOP=1 -c "CREATE TABLE IF NOT EXISTS admins (id BIGSERIAL PRIMARY KEY, email TEXT NOT NULL UNIQUE, password_hash TEXT NOT NULL, full_name TEXT NOT NULL, is_active BOOLEAN NOT NULL DEFAULT TRUE, created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(), updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW());"
${PSQL_CMD} -v ON_ERROR_STOP=1 -c "CREATE INDEX IF NOT EXISTS idx_admins_email ON admins(email);"

# --- Schema: residents ---
${PSQL_CMD} -v ON_ERROR_STOP=1 -c "CREATE TABLE IF NOT EXISTS residents (id BIGSERIAL PRIMARY KEY, first_name TEXT NOT NULL, last_name TEXT NOT NULL, unit_number TEXT, address_line1 TEXT, address_line2 TEXT, city TEXT, state TEXT, postal_code TEXT, phone TEXT, email TEXT, emergency_contact_name TEXT, emergency_contact_phone TEXT, notes TEXT, is_active BOOLEAN NOT NULL DEFAULT TRUE, created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(), updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW());"
${PSQL_CMD} -v ON_ERROR_STOP=1 -c "CREATE INDEX IF NOT EXISTS idx_residents_name ON residents(last_name, first_name);"
${PSQL_CMD} -v ON_ERROR_STOP=1 -c "CREATE INDEX IF NOT EXISTS idx_residents_unit ON residents(unit_number);"

# --- Schema: resident_photos (metadata only) ---
${PSQL_CMD} -v ON_ERROR_STOP=1 -c "CREATE TABLE IF NOT EXISTS resident_photos (id BIGSERIAL PRIMARY KEY, resident_id BIGINT NOT NULL REFERENCES residents(id) ON DELETE CASCADE, storage_provider TEXT NOT NULL DEFAULT 'local', object_key TEXT NOT NULL, content_type TEXT, file_name TEXT, byte_size BIGINT, width INT, height INT, checksum_sha256 TEXT, created_at TIMESTAMPTZ NOT NULL DEFAULT NOW());"
${PSQL_CMD} -v ON_ERROR_STOP=1 -c "CREATE INDEX IF NOT EXISTS idx_resident_photos_resident_id ON resident_photos(resident_id);"

# Seed data
# NOTE: password_hash is a placeholder. Backend should verify using its configured hashing scheme.
${PSQL_CMD} -v ON_ERROR_STOP=1 -c "INSERT INTO admins (email, password_hash, full_name, is_active) VALUES ('admin@example.com', 'CHANGE_ME_IN_BACKEND', 'Default Admin', TRUE) ON CONFLICT (email) DO NOTHING;"

${PSQL_CMD} -v ON_ERROR_STOP=1 -c "INSERT INTO residents (first_name, last_name, unit_number, address_line1, city, state, postal_code, phone, email, emergency_contact_name, emergency_contact_phone, notes, is_active) VALUES ('Ava', 'Johnson', '1A', '123 Main St', 'Springfield', 'IL', '62701', '+1-555-0101', 'ava.johnson@example.com', 'Mark Johnson', '+1-555-0199', 'Prefers email contact.', TRUE) ON CONFLICT DO NOTHING;"
${PSQL_CMD} -v ON_ERROR_STOP=1 -c "INSERT INTO residents (first_name, last_name, unit_number, address_line1, city, state, postal_code, phone, email, emergency_contact_name, emergency_contact_phone, notes, is_active) VALUES ('Noah', 'Patel', '2B', '123 Main St', 'Springfield', 'IL', '62701', '+1-555-0102', 'noah.patel@example.com', 'Rina Patel', '+1-555-0188', 'Has a service animal.', TRUE) ON CONFLICT DO NOTHING;"
${PSQL_CMD} -v ON_ERROR_STOP=1 -c "INSERT INTO residents (first_name, last_name, unit_number, address_line1, city, state, postal_code, phone, email, emergency_contact_name, emergency_contact_phone, notes, is_active) VALUES ('Mia', 'Chen', '3C', '123 Main St', 'Springfield', 'IL', '62701', '+1-555-0103', 'mia.chen@example.com', 'Li Chen', '+1-555-0177', 'Allergic to peanuts.', TRUE) ON CONFLICT DO NOTHING;"

# Seed photo metadata for one resident (if resident exists)
${PSQL_CMD} -v ON_ERROR_STOP=1 -c "INSERT INTO resident_photos (resident_id, storage_provider, object_key, content_type, file_name, byte_size, width, height) SELECT r.id, 'local', 'seed/ava-johnson.jpg', 'image/jpeg', 'ava-johnson.jpg', 0, NULL, NULL FROM residents r WHERE r.first_name='Ava' AND r.last_name='Johnson' LIMIT 1;"

echo "Schema + seed complete."
