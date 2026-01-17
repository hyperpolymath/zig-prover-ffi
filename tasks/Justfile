# SPDX-License-Identifier: MPL-2.0
# Palimpsest: https://github.com/hyperpolymath/palimpsest-license
# zig-prover-ffi Task Runner

default:
    @just --list

build:
    zig build

test:
    zig build test

clean:
    rm -rf zig-out .zig-cache

rsr-check:
    @echo "Checking RSR compliance..."
    @test -f README.adoc && echo "✓ README.adoc" || echo "✗ README.adoc"
    @test -f LICENSE && echo "✓ LICENSE" || echo "✗ LICENSE"
    @test -f STATE.scm && echo "✓ STATE.scm" || echo "✗ STATE.scm"
    @test -f META.scm && echo "✓ META.scm" || echo "✗ META.scm"
    @test -f ECOSYSTEM.scm && echo "✓ ECOSYSTEM.scm" || echo "✗ ECOSYSTEM.scm"
