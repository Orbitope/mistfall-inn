# Vendored addon — do not edit here

`addons/parlance/` is an installed copy of the Parlance GDScript runtime, not
its source. Upstream is:

    https://github.com/Orbitope/parlance-gdscript

Fix bugs there, then re-copy. A patch applied only here is invisible to the
conformance suite — this repo does not carry the vectors — so it would look
correct while diverging from the format the addon claims to implement.

Upstream also holds `conformance/` and `schema/`, and runs the vectors in CI.
