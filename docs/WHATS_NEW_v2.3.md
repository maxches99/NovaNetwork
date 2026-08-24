# What's New in 2.3

## Multipart form-data and file-streamed uploads

- Added `MultipartFormDataEncoder` and `MultipartFormDataPart` (`.text`, `.data`, `.file`):
  streams a `multipart/form-data` body to disk in fixed 64 KiB chunks. File parts are read
  directly from their source file and are never fully buffered in memory, regardless of size.
  `contentLength()` computes the exact encoded byte count from filesystem metadata alone,
  without reading file contents.
- Field names and filenames are sanitized before being placed in a quoted
  `Content-Disposition` header value (quotes are percent-escaped, CR/LF are stripped), so a
  caller-supplied filename cannot inject additional multipart headers or break part framing.
- Added `TransferNetworkTransport.upload(_:fromFile:)`, with a default protocol-extension
  implementation (reads the file and delegates to the existing `body:`-based overload) so
  existing custom transports remain source-compatible without changes. The default `Transport`
  overrides it with a real streamed-from-disk implementation via
  `URLSession.upload(for:fromFile:)`.
- Added `NetworkClient.upload(request:fromFile:authScope:options:)`, mirroring the existing
  `body:`-based `upload`, and `NetworkClient.uploadMultipart(...)`, a convenience that encodes
  parts to a private temporary file, uploads it, and removes the temporary file when the upload
  finishes (success, failure, or cancellation).
- `MultipartFormDataEncoder` is decoupled from any specific upload path: `write(to:)` accepts
  any destination file, so the encoded body can be handed to a different file-based upload flow
  (for example a durable/resumable one) instead of `uploadMultipart`'s own upload-then-cleanup
  flow.

## Migration notes

- Additive only; no existing public API changed. `TransferNetworkTransport` gained a new
  protocol requirement, but its default extension implementation means existing conformers do
  not need any code changes.
