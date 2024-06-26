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
  - seems like we need to break fuse_main into its constituent parts and use those
- [ ] copy on write
- [ ] paste on read
- [ ] explore directory structure options
  - e.g. selections/* copies to other selections
- [ ] display all paste options when someone else has the clipboard
  - You can use XFixes to get that notification
  - https://github.com/cdown/clipnotify/blob/master/clipnotify.c

### Phase III: polish

- [ ] make sure there's adequate unit testing
- [ ] make sure there's adequate integration testing
- [ ] make sure all the relevant file operations are supported
- [ ] consider factoring bindings into separate repos
- [ ] compile via nix
- [ ] NixOS service to automatically mount
- [ ] refactor code to be more intuitive to read
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

### x11 selections

- http://www.uninformativ.de/blog/postings/2017-04-02/0/POSTING-en.html
- https://www.jwz.org/doc/x-cut-and-paste.html
- xclip -t

### fuse

- https://richiejp.com/zig-fuse-one
- https://richiejp.com/zig-fuse-two
- https://stackoverflow.com/questions/31601272/how-can-i-create-a-userspace-filesystem-with-fuse-without-using-libfuse
- https://www.kernel.org/doc/html/next/filesystems/fuse.html
- https://www.man7.org/linux/man-pages/man4/fuse.4.html
- https://billauer.co.il/blog/2020/02/fuse-cuse-kernel-driver-details/
- https://billauer.co.il/blog/2020/02/linux-cuse-fuse-libfuse-crash/
- https://john-millikin.com/the-fuse-protocol
- http://libfuse.github.io/doxygen/structfuse__operations.html
- https://nuetzlich.net/the-fuse-wire-protocol/
- https://github.com/hanwen/go-fuse/blob/master/fuse/opcode.go
- http://ptspts.blogspot.com/2009/11/fuse-protocol-tutorial-for-linux-26.html
- https://stackoverflow.com/questions/11071996/what-are-inode-generation-numbers
- Read the kernel source code.




- everything can be driven by either paste or filesystem requests
- use a generational index on the clipboard, and use that as a filehandle
  - we can either keep clipboards around in an array until the file is closed, or can just invalidate them immediately on a new copy
- figure out what target a .tar.gz file counts as
