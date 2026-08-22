run *args:
  zig build run -- {{args}}

watch:
  watchexec -c -w src zig build
