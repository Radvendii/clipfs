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

- [x] figure out how to use FUSE non-blocking
  - seems like we need to break fuse_main into its constituent parts and use those
  - decided to use /dev/fuse directly
- [x] copy on write
- [ ] paste on read
- [ ] explore directory structure options
  - e.g. selections/* copies to other selections
- [ ] display all paste options when someone else has the clipboard
  - You can use XFixes to get that notification
  - https://github.com/cdown/clipnotify/blob/master/clipnotify.c
  - Or we can just query whenever we get the readdir(plus) op

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

- [ ] consider using /dev/fd/ file descriptor with already mounted /dev/fuse so it's an entirely separate process opening and mounting /dev/fuse
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
- https://github.com/richiejp/m/tree/main
- Read the kernel source code.
- https://github.com/hinshun/hellofs
- fusermount doesn't check that it can write to `_FUSE_COMMFD` before mounting...

### interrupts

- https://www.oreilly.com/library/view/linux-device-drivers/0596000081/ch09s05.html
- https://www.openmymind.net/Writing-a-Task-Scheduler-in-Zig/




- everything can be driven by either paste or filesystem requests
- use a generational index on the clipboard, and use that as a filehandle
  - we can either keep clipboards around in an array until the file is closed, or can just invalidate them immediately on a new copy
- figure out what target a .tar.gz file counts as



---

- when we get a new clipboard, we can up the generation number (and refresh `ino`s)
- we can have `ino`s correspond to the place in the list of targets

---

how to deal with filling up `Dirent`s.

- i don't like the way libfuse does it. you give it a callback, which takes in a buffer and a callback to your callback. you call the callback for every dirent you want to add. too complicated.
- i don't have to settle on one solution. there can be multiple entrypoints and you just have to choose one.
  - could even use the same function name and just change what arguments you take, but that seems like a terrible idea to me. don't abuse dynamic typing
- one option is the callback hell.
- a slight modification on that is to have the filler callback be a method on the buffer, like "append". that way you have fewer things to keep track of.
- another slight modification is that the API is you just get the buffer, and it's your job to fill it with dirents. handy for you, there's a library function that makes this easier. might be easier to conceptualise.
- your function returns an iterator that itself returns dirents. our fuse library will call it one by one until we get the number we need.
  - also two layers of callback, but at least it's in the same direction...
