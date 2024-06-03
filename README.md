# ClipFS

- SelFS
- SelectionFS
- CopyFS
- COWFS
- XSelFS

## Roadmap

### Phase I: pieces

- [x] copy to the clipboard
  - via x11 integration
- [x] send the proper responses for different targets
- [x] create a FUSE filesytem
  - only needs to allow writing files
  - alternative: watch an actual directory
- [x] read MIME type from documents

### Phase II: integration

- [ ] figure out how to use FUSE non-blocking
- [ ] copy on write
- [ ] paste on read

### Phase III: polish

- [ ] make sure there's adequate unit testing
- [ ] make sure there's adequate integration testing
- [ ] consider factoring bindings into separate repos
- [ ] compile via nix
- [ ] NixOS service to automatically mount
- [ ] deal with all TODOs and XXXs
- [ ] documentation
  - [ ] proper readme
  - [ ] comments
- [ ] blog post

### further work

- [ ] more extensive x11/magic/fuse bindings
- [ ] /dev/fuse 
  - https://richiejp.com/zig-fuse-two
  - https://github.com/shanoaice/zig-fuse


## Useful Resources

- https://richiejp.com/zig-fuse-one
- http://libfuse.github.io/doxygen/structfuse__operations.html
