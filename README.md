# notmuch-jmap

A [JMAP](https://jmap.io/) server that is a thin client for [notmuch](https://notmuchmail.org/)


## Dependencies

  - json
    - dkjson fails on deeply nested objects
    - lua-cjson doesn't have empty array vs object support
    - lua-cjson OpenResty fork fails with https://github.com/openresty/lua-cjson/issues/67
  - lpeg_patterns (need https://github.com/daurnimator/lpeg_patterns/pull/20/)
  - lua-http
  - lua-spawn
