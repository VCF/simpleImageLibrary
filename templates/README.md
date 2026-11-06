# Simple Image Library - Template Sources

This folder contains template files that will be used to set up new
objects, generally configuring new image libraries

| File            | Copied into a library as | Purpose                          |
| --------------- | ------------------------ | -------------------------------- |
| `sil.conf`      | `sil.conf`               | Library settings (REQ-02)        |
| `gitignore`     | `.gitignore`             | Keeps temp files, logs and replaced images out of git (REQ-10) |
| `gitattributes` | `.gitattributes`         | Lets git merge the fingerprint index (REQ-10) |

`gitignore` and `gitattributes` have no leading dot here, as git would otherwise
apply them to this folder of the SIL repository itself.
