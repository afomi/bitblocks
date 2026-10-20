# The declarative, prefix-only Bitcom protocol handlers: detection is just
# "a piped segment starts with this protocol address" — no deep parser yet.
# One-liners, grouped here; a handler that grows a parse/1 graduates to its
# own file (see twetch.ex / metanet.ex / order_book.ex).

defmodule Bitblocks.Protocol.Handlers.B do
  use Bitblocks.Protocol.Handler,
    name: "B://",
    prefix: "19HxigV4QyBv3tHpQVcUEQyq1pzZVdoAut"
end

defmodule Bitblocks.Protocol.Handlers.Map do
  use Bitblocks.Protocol.Handler,
    name: "MAP",
    prefix: "1PuQa7K62MiKCtssSLKy1kh56WWU7MtUR5"
end

defmodule Bitblocks.Protocol.Handlers.Haip do
  use Bitblocks.Protocol.Handler,
    name: "HAIP",
    prefix: "1HA1P2exomAwCUycZHr8WeyFoy5vuQASE3"
end

defmodule Bitblocks.Protocol.Handlers.RelayX do
  use Bitblocks.Protocol.Handler,
    name: "RelayX",
    prefix: "1LtyME6b5AnMopQrBPLk4FGN8UBuhxKqrn"
end

defmodule Bitblocks.Protocol.Handlers.BCat do
  use Bitblocks.Protocol.Handler,
    name: "BCat",
    prefix: "15DHFxWZJT58f9nhyCA3mREYYzkVDetm6A"
end
