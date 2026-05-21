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
           "Learn what Bitblocks is, why it focuses on Bitcoin SV, and how it approaches scalable block exploration and protocol visibility.",
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
            Bitblocks is a Bitcoin SV blockchain explorer that provides real-time access to blocks, transactions, and protocol data on the BSV network.
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
                href="#bitcoin-sv"
                class="block text-sm text-neutral-500 hover:text-neutral-50 transition-colors duration-150 py-1"
              >
                Bitcoin SV
              </a>
              <a
                href="#scalable-blocks"
                class="block text-sm text-neutral-500 hover:text-neutral-50 transition-colors duration-150 py-1"
              >
                Scalable Blocks
              </a>
              <a
                href="#bitcoin-script"
                class="block text-sm text-neutral-500 hover:text-neutral-50 transition-colors duration-150 py-1"
              >
                Bitcoin Script
              </a>
              <a
                href="#learn-more"
                class="block text-sm text-neutral-500 hover:text-neutral-50 transition-colors duration-150 py-1"
              >
                Learn More
              </a>
            </div>
          </nav>

          <%!-- Main content --%>
          <div class="flex-1 min-w-0">
            <%!-- Bitcoin SV Section --%>
            <section
              id="bitcoin-sv"
              class="border-b border-neutral-800 pb-8 mb-8 scroll-mt-8"
            >
              <p class="font-mono text-xs text-neutral-500 uppercase tracking-wider mb-2">
                Network
              </p>
              <h2 class="text-2xl font-semibold text-neutral-50 mb-3">
                Bitcoin SV
              </h2>
              <div class="text-neutral-500 leading-relaxed space-y-2">
                <p>
                  Bitcoin SV (Satoshi Vision) is the original Bitcoin protocol, restored and stabilized to fulfill Satoshi Nakamoto's vision of peer-to-peer electronic cash.
                </p>
                <p>
                  BSV maintains Bitcoin's fundamental design while removing artificial limitations, enabling massive on-chain scaling and unlimited possibilities for applications.
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
                Scalable Blocks
              </h2>
              <p class="text-neutral-500 leading-relaxed mb-3">
                Unlike other blockchains with artificial block size limits, BSV has unbounded block sizes that scale with network demand.
              </p>
              <div class="border-t border-neutral-800">
                <div class="py-2 border-b border-neutral-800">
                  <p class="text-sm text-neutral-400">
                    Massive transaction throughput (millions of transactions per block)
                  </p>
                </div>
                <div class="py-2 border-b border-neutral-800">
                  <p class="text-sm text-neutral-400">
                    Extremely low transaction fees (fractions of a cent)
                  </p>
                </div>
                <div class="py-2 border-b border-neutral-800">
                  <p class="text-sm text-neutral-400">
                    On-chain data storage and complex applications
                  </p>
                </div>
                <div class="py-2 border-b border-neutral-800">
                  <p class="text-sm text-neutral-400">
                    Global scale for enterprise and consumer applications
                  </p>
                </div>
              </div>
              <p class="text-neutral-500 leading-relaxed mt-3">
                BSV has proven this capability with multi-gigabyte blocks, demonstrating that blockchain can scale to meet real-world demands.
              </p>
            </section>

            <%!-- Bitcoin Script Section --%>
            <section
              id="bitcoin-script"
              class="border-b border-neutral-800 pb-8 mb-8 scroll-mt-8"
            >
              <p class="font-mono text-xs text-neutral-500 uppercase tracking-wider mb-2">
                Programmability
              </p>
              <h2 class="text-2xl font-semibold text-neutral-50 mb-3">
                Bitcoin Script
              </h2>
              <p class="text-neutral-500 leading-relaxed mb-3">
                Bitcoin Script is the original smart contract language built into Bitcoin.
                It's a simple, stack-based programming language that defines the conditions under which bitcoins can be spent.
                BSV has restored the full power of Bitcoin Script by:
              </p>
              <div class="border-t border-neutral-800">
                <div class="py-2 border-b border-neutral-800">
                  <p class="text-sm text-neutral-400">
                    Re-enabling originally disabled opcodes
                  </p>
                </div>
                <div class="py-2 border-b border-neutral-800">
                  <p class="text-sm text-neutral-400">
                    Removing arbitrary script size limitations
                  </p>
                </div>
                <div class="py-2 border-b border-neutral-800">
                  <p class="text-sm text-neutral-400">
                    Supporting complex smart contracts and logic
                  </p>
                </div>
                <div class="py-2 border-b border-neutral-800">
                  <p class="text-sm text-neutral-400">
                    Enabling tokens, NFTs, and sophisticated applications
                  </p>
                </div>
              </div>
            </section>

            <%!-- Additional Links --%>
            <section
              id="learn-more"
              class="pb-8 scroll-mt-8"
            >
              <h2 class="text-lg font-semibold text-neutral-50 mb-3">
                Learn More
              </h2>
              <div class="border-t border-neutral-800">
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
                <a
                  href="https://bitcoinsv.com/"
                  target="_blank"
                  rel="noopener noreferrer"
                  class="flex items-center justify-between py-3 border-b border-neutral-800 group"
                >
                  <span class="text-sm text-neutral-400 group-hover:text-neutral-50 transition-colors duration-150">
                    BitcoinSV.com
                  </span>
                  <span class="text-neutral-700 group-hover:text-brand transition-colors duration-150">
                    →
                  </span>
                </a>
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
              </div>
            </section>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
