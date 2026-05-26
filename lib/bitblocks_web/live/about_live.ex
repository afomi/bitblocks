defmodule BitblocksWeb.AboutLive do
  use BitblocksWeb, :live_view

  alias BitblocksWeb.Seo

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(
       socket,
       Seo.public_page(
         page_title: "About Bitblocks",
         meta_description:
           "Bitblocks is a block explorer for a scalable public ledger. Browse blocks, transactions, and on-chain protocols in real time.",
         canonical_path: "/about"
       )
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="bg-surface-base min-h-screen">
      <div class="max-w-7xl mx-auto px-4">
        <section class="border-b border-neutral-800 pt-10 pb-6">
          <h1 class="text-4xl font-semibold text-neutral-50 tracking-tight mb-3">
            About Bitblocks
          </h1>
          <p class="text-lg text-neutral-400 leading-relaxed">
            A block explorer for a scalable public ledger.
            Real-time access to blocks, transactions, and on-chain protocols.
          </p>
        </section>

        <div class="flex gap-12 py-8">
          <%!-- Left sidebar TOC --%>
          <nav class="hidden md:block w-48 shrink-0 sticky top-8 self-start">
            <p class="font-mono text-xs text-neutral-500 uppercase tracking-wider mb-3">
              On this page
            </p>
            <div class="space-y-1">
              <a
                href="#what-it-does"
                class="block text-sm text-neutral-500 hover:text-neutral-50 transition-colors duration-150 py-1"
              >
                What it does
              </a>
              <a
                href="#scalable-blocks"
                class="block text-sm text-neutral-500 hover:text-neutral-50 transition-colors duration-150 py-1"
              >
                Scalable blocks
              </a>
              <a
                href="#on-chain-programs"
                class="block text-sm text-neutral-500 hover:text-neutral-50 transition-colors duration-150 py-1"
              >
                On-chain programs
              </a>
              <a
                href="#learn-more"
                class="block text-sm text-neutral-500 hover:text-neutral-50 transition-colors duration-150 py-1"
              >
                Learn more
              </a>
            </div>
          </nav>

          <%!-- Main content --%>
          <div class="flex-1 min-w-0">
            <%!-- What it does --%>
            <section
              id="what-it-does"
              class="border-b border-neutral-800 pb-8 mb-8 scroll-mt-8"
            >
              <p class="font-mono text-xs text-neutral-500 uppercase tracking-wider mb-2">
                Explorer
              </p>
              <h2 class="text-2xl font-semibold text-neutral-50 mb-3">
                What it does
              </h2>
              <div class="text-neutral-500 leading-relaxed space-y-2">
                <p>
                  Bitblocks indexes a public ledger and makes its contents browsable.
                  Blocks, transactions, scripts, and protocol data are synced from a node and presented through a web interface and API.
                </p>
                <p>
                  The ledger it indexes is Bitcoin SV — a network that kept the original protocol's unbounded design, making it possible to explore blocks with millions of transactions and on-chain data of any size.
                </p>
              </div>
            </section>

            <%!-- Scalable Blocks Section --%>
            <section
              id="scalable-blocks"
              class="border-b border-neutral-800 pb-8 mb-8 scroll-mt-8"
            >
              <p class="font-mono text-xs text-neutral-500 uppercase tracking-wider mb-2">
                Scale
              </p>
              <h2 class="text-2xl font-semibold text-neutral-50 mb-3">
                Scalable blocks
              </h2>
              <p class="text-neutral-500 leading-relaxed mb-3">
                Most blockchains cap block size, which caps throughput.
                The ledger Bitblocks indexes has no such cap — blocks grow with demand.
              </p>
              <div class="border-t border-neutral-800">
                <div class="py-2 border-b border-neutral-800">
                  <p class="text-sm text-neutral-400">
                    Millions of transactions per block
                  </p>
                </div>
                <div class="py-2 border-b border-neutral-800">
                  <p class="text-sm text-neutral-400">
                    Sub-cent transaction fees
                  </p>
                </div>
                <div class="py-2 border-b border-neutral-800">
                  <p class="text-sm text-neutral-400">
                    Arbitrary data stored on-chain
                  </p>
                </div>
                <div class="py-2 border-b border-neutral-800">
                  <p class="text-sm text-neutral-400">
                    Multi-gigabyte blocks already produced in practice
                  </p>
                </div>
              </div>
              <p class="text-neutral-500 leading-relaxed mt-3">
                This changes what a block explorer needs to handle.
                Bitblocks is built for blocks that contain real workloads, not just financial transfers.
              </p>
            </section>

            <%!-- On-chain Programs Section --%>
            <section
              id="on-chain-programs"
              class="border-b border-neutral-800 pb-8 mb-8 scroll-mt-8"
            >
              <p class="font-mono text-xs text-neutral-500 uppercase tracking-wider mb-2">
                Programmability
              </p>
              <h2 class="text-2xl font-semibold text-neutral-50 mb-3">
                On-chain programs
              </h2>
              <p class="text-neutral-500 leading-relaxed mb-3">
                Every transaction contains a script — a small program that defines the conditions for spending.
                With the full original instruction set available, these scripts can express:
              </p>
              <div class="border-t border-neutral-800">
                <div class="py-2 border-b border-neutral-800">
                  <p class="text-sm text-neutral-400">
                    Tokens and digital assets
                  </p>
                </div>
                <div class="py-2 border-b border-neutral-800">
                  <p class="text-sm text-neutral-400">
                    Multi-party conditions and escrow
                  </p>
                </div>
                <div class="py-2 border-b border-neutral-800">
                  <p class="text-sm text-neutral-400">
                    On-chain data protocols (Metanet, MAP, B)
                  </p>
                </div>
                <div class="py-2 border-b border-neutral-800">
                  <p class="text-sm text-neutral-400">
                    Application logic without script size limits
                  </p>
                </div>
              </div>
              <p class="text-neutral-500 leading-relaxed mt-3">
                Bitblocks parses these protocols and makes them visible — not just the raw hex, but the structured data inside.
              </p>
            </section>

            <%!-- Learn More --%>
            <section
              id="learn-more"
              class="pb-8 scroll-mt-8"
            >
              <h2 class="text-lg font-semibold text-neutral-50 mb-3">
                Learn more
              </h2>
              <div class="border-t border-neutral-800">
                <a
                  href="https://github.com/afomi/bitblocks"
                  target="_blank"
                  rel="noopener noreferrer"
                  class="flex items-center justify-between py-3 border-b border-neutral-800 group"
                >
                  <span class="text-sm text-neutral-400 group-hover:text-neutral-50 transition-colors duration-150">
                    Bitblocks on GitHub
                  </span>
                  <span class="text-neutral-700 group-hover:text-brand transition-colors duration-150">
                    →
                  </span>
                </a>
                <a
                  href="https://wiki.bitcoinsv.io/"
                  target="_blank"
                  rel="noopener noreferrer"
                  class="flex items-center justify-between py-3 border-b border-neutral-800 group"
                >
                  <span class="text-sm text-neutral-400 group-hover:text-neutral-50 transition-colors duration-150">
                    Bitcoin SV Wiki
                  </span>
                  <span class="text-neutral-700 group-hover:text-brand transition-colors duration-150">
                    →
                  </span>
                </a>
              </div>
            </section>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
