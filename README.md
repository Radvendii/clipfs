# ClipFS

## Roadmap

- [x] copy to the clipboard
  - via x11 integration
- [ ] send the proper responses for different targets
- [ ] create a FUSE filesytem
  - only needs to allow writing files
  - alternative: watch an actual directory
- [ ] read MIME type from documents

problem: for x11, we want to be driving the hot loop. for FUSE, we only get to regisster callbcaks I think.
