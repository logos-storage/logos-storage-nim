## Nim-Codex
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

## Partially taken from nim beacon chain

{.push raises: [], gcsafe.}

import std/strutils
import pkg/stew/io2

import ../logutils

export io2
export logutils

when defined(windows):
  import stew/[windows/acl]

proc secureCreatePath*(path: string): IoResult[void] =
  when defined(windows):
    let sres = createFoldersUserOnlySecurityDescriptor()
    if sres.isErr():
      error "Could not allocate security descriptor",
        path = path, errorMsg = ioErrorMsg(sres.error), errorCode = $sres.error
      err(sres.error)
    else:
      var sd = sres.get()
      createPath(path, 0o700, secDescriptor = sd.getDescriptor())
  else:
    createPath(path, 0o700)

proc secureWriteFile*[T: byte | char](
    path: string, data: openArray[T]
): IoResult[void] =
  when defined(windows):
    let sres = createFilesUserOnlySecurityDescriptor()
    if sres.isErr():
      error "Could not allocate security descriptor",
        path = path, errorMsg = ioErrorMsg(sres.error), errorCode = $sres.error
      err(sres.error)
    else:
      var sd = sres.get()
      writeFile(path, data, 0o600, secDescriptor = sd.getDescriptor())
  else:
    writeFile(path, data, 0o600)

proc checkSecureFile*(path: string): IoResult[bool] =
  when defined(windows):
    checkCurrentUserOnlyACL(path)
  else:
    ok (?getPermissionsSet(path) == {UserRead, UserWrite})

proc checkAndCreateDataDir*(dataDir: string): bool =
  when defined(posix):
    let requiredPerms = 0o700
    if isDir(dataDir):
      let currPermsRes = getPermissions(dataDir)
      if currPermsRes.isErr():
        fatal "Could not check data directory permissions",
          data_dir = dataDir,
          errorCode = $currPermsRes.error,
          errorMsg = ioErrorMsg(currPermsRes.error)
        return false
      else:
        let currPerms = currPermsRes.get()
        if currPerms != requiredPerms:
          warn "Data directory has insecure permissions. Correcting them.",
            data_dir = dataDir,
            current_permissions = currPerms.toOct(4),
            required_permissions = requiredPerms.toOct(4)
          let newPermsRes = setPermissions(dataDir, requiredPerms)
          if newPermsRes.isErr():
            fatal "Could not set data directory permissions",
              data_dir = dataDir,
              errorCode = $newPermsRes.error,
              errorMsg = ioErrorMsg(newPermsRes.error),
              old_permissions = currPerms.toOct(4),
              new_permissions = requiredPerms.toOct(4)
            return false
    else:
      let res = secureCreatePath(dataDir)
      if res.isErr():
        fatal "Could not create data directory",
          data_dir = dataDir, errorMsg = ioErrorMsg(res.error), errorCode = $res.error
        return false
  elif defined(windows):
    let amask = {AccessFlags.Read, AccessFlags.Write, AccessFlags.Execute}
    if fileAccessible(dataDir, amask):
      let cres = checkCurrentUserOnlyACL(dataDir)
      if cres.isErr():
        fatal "Could not check data folder's ACL",
          data_dir = dataDir, errorCode = $cres.error, errorMsg = ioErrorMsg(cres.error)
        return false
      else:
        if cres.get() == false:
          fatal "Data folder has insecure ACL", data_dir = dataDir
          return false
    else:
      let res = secureCreatePath(dataDir)
      if res.isErr():
        fatal "Could not create data folder",
          data_dir = dataDir, errorMsg = ioErrorMsg(res.error), errorCode = $res.error
        return false
  else:
    fatal "Unsupported operation system"
    return false

  return true
