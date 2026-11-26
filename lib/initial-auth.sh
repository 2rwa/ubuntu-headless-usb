#!/usr/bin/env bash
# Initial console secret stays in shell memory; never pass it as an argument.
usb_password_valid() {
  local LC_ALL=C
  [[ $1 =~ ^[!-~]{8,64}$ ]]
}
usb_prompt_password() {
  local candidate confirmation TMOUT=0
  while :; do
    printf 'Initial password (8-64 printable ASCII characters, no spaces): ' >&2
    IFS= read -rs candidate || { printf '\nCancelled.\n' >&2; return 1; }
    printf '\n' >&2
    if ! usb_password_valid "$candidate"; then
      printf 'Invalid length or characters. Try again.\n' >&2
      continue
    fi
    printf 'Confirm initial password: ' >&2
    IFS= read -rs confirmation || { printf '\nCancelled.\n' >&2; return 1; }
    printf '\n' >&2
    if [[ $candidate != "$confirmation" ]]; then
      printf 'Passwords do not match. Try again.\n' >&2
      continue
    fi
    PASS=$candidate
    return 0
  done
}
usb_verify_password() {
  # Both crypt() and the hash being checked belong to the target Ubuntu,
  # not the builder. Only the user name (not the password/hash) is in argv.
  printf '%s\n' "$PASS" | chroot "$ROOT" /usr/bin/perl -e '
    use strict; use warnings;
    my $user = shift @ARGV;
    my $password = <STDIN>;
    exit 1 unless defined $password;
    chomp $password;
    open my $fh, "<", "/etc/shadow" or exit 2;
    while (<$fh>) {
      chomp;
      my ($name, $hash, $changed) = split /:/;
      next unless $name eq $user;
      exit 1 unless defined($hash) && $hash =~ /^\$/ && $changed eq "0";
      my $actual = crypt($password, $hash);
      exit(defined($actual) && $actual eq $hash ? 0 : 1);
    }
    exit 1;
  ' "$LOGIN_USER"
}
usb_set_login_timeout() {
  local file=$1
  sed -i -E '/^[[:space:]]*LOGIN_TIMEOUT([[:space:]]|$)/d' "$file" || return
  printf '\n# Local console: allow time for initial PAM password change.\nLOGIN_TIMEOUT 180\n' >> "$file"
}
