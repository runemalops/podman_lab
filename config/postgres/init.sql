-- Create users and databases for podman-lab services
-- These are executed at first PostgreSQL startup only.
-- Passwords are injected at deploy time by setup.sh via
-- init.d/init.sql (which replaces this file).

CREATE USER gitea;
CREATE DATABASE gitea OWNER gitea;
CREATE USER woodpecker;
CREATE DATABASE woodpecker OWNER woodpecker;
