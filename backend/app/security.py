import hashlib
import hmac
import secrets
from datetime import UTC, datetime, timedelta


PASSWORD_HASH_ITERATION_COUNT = 100_000
SESSION_DURATION_DAYS = 30


def normalize_email_address(email_address: str) -> str:
    return email_address.strip().lower()


def create_password_hash(password: str) -> str:
    password_salt = secrets.token_hex(16)
    password_hash_bytes = hashlib.pbkdf2_hmac(
        "sha256",
        password.encode("utf-8"),
        password_salt.encode("utf-8"),
        PASSWORD_HASH_ITERATION_COUNT,
    )
    return (
        f"pbkdf2_sha256${PASSWORD_HASH_ITERATION_COUNT}"
        f"${password_salt}${password_hash_bytes.hex()}"
    )


def verify_password(password: str, stored_password_hash: str | None) -> bool:
    if not stored_password_hash:
        return False

    try:
        algorithm_name, iteration_count_text, password_salt, expected_hash = (
            stored_password_hash.split("$", 3)
        )
    except ValueError:
        return False

    if algorithm_name != "pbkdf2_sha256":
        return False

    derived_hash = hashlib.pbkdf2_hmac(
        "sha256",
        password.encode("utf-8"),
        password_salt.encode("utf-8"),
        int(iteration_count_text),
    ).hex()

    return hmac.compare_digest(derived_hash, expected_hash)


def create_session_token() -> str:
    return secrets.token_urlsafe(32)


def hash_session_token(session_token: str) -> str:
    return hashlib.sha256(session_token.encode("utf-8")).hexdigest()


def create_session_expiration_datetime() -> datetime:
    return datetime.now(UTC) + timedelta(days=SESSION_DURATION_DAYS)
