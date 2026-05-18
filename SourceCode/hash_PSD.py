import hashlib
import os
import binascii

def rdsalt():
    return binascii.hexlify(os.urandom(16)).decode()

def hash(password: str, salt: str = None) -> tuple:
    if salt is None:
        salt = rdsalt()
    hash = hashlib.sha512((salt + password).encode()).hexdigest()
    return (salt, hash)