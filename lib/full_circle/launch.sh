# Build Docker Image
docker build -t tankwanghow/fullcircle .

#Push Docker image to docker hub
docker push tankwanghow/fullcircle .







-- Create a new role
CREATE ROLE full_circle WITH LOGIN PASSWORD 'nyhlisted';
CREATE ROLE full_circle_query WITH LOGIN PASSWORD 'nyhlisted';

-- Grant superuser privileges if needed
ALTER ROLE full_circle WITH SUPERUSER;

-- Create a new database
CREATE DATABASE fullcircle WITH OWNER = full_circle;

\c fullcircle

CREATE EXTENSION IF NOT EXISTS citext WITH SCHEMA public;
