#!/bin/sh
# What the unit tests' stand-in for Authelia answers to `storage …`: `migrate up`
# has nothing to do; `user totp generate NAME … --path FILE` registers an
# authenticator the way Authelia reports it, and writes its QR code (a PNG
# signature is enough).
[ "$2" = user ] || exit 0
name="$5"
while [ $# -gt 0 ]; do
    [ "$1" = --path ] && path="$2"
    shift
done
printf '\211PNG\r\n\032\n' > "$path"
echo "Successfully generated TOTP configuration for user '$name' with URI 'otpauth://totp/team.example.com:$name?algorithm=SHA1&digits=6&issuer=team.example.com&period=30&secret=FAKESECRET' and saved it as a PNG image at the path '$path'"
