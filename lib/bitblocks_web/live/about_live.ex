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
        <section class="border-b border-neutral-800 pt-16 pb-20">
          <h1 class="text-4xl font-semibold text-neutral-50 tracking-tight">
            About Bitblocks
          </h1>
        </section>

        <%!-- Introduction --%>
        <section class="border-b border-neutral-800 py-16">
          <p class="text-lg text-neutral-400 leading-relaxed mb-4">
            Bitblocks is a Bitcoin SV blockchain explorer that provides real-time access to blocks, transactions, and protocol data on the BSV network.
          </p>
          <p class="text-neutral-500 leading-relaxed">
            We're building tools to make the Bitcoin SV blockchain more accessible and easier to understand for developers, researchers, and enthusiasts.
          </p>
        </section>

        <%!-- Bitcoin SV Section --%>
        <section class="border-b border-neutral-800 py-16">
          <p class="font-mono text-xs text-neutral-500 uppercase tracking-wider mb-4">
            Network
          </p>
          <h2 class="text-2xl font-semibold text-neutral-50 mb-6">
            Bitcoin SV
          </h2>
          <div class="text-neutral-500 leading-relaxed space-y-4">
            <p>
              Bitcoin SV (Satoshi Vision) is the original Bitcoin protocol, restored and stabilized to fulfill Satoshi Nakamoto's vision of peer-to-peer electronic cash.
            </p>
            <p>
              BSV maintains Bitcoin's fundamental design while removing artificial limitations, enabling massive on-chain scaling and unlimited possibilities for applications.
            </p>
          </div>
        </section>

        <%!-- Scalable Blocks Section --%>
        <section class="border-b border-neutral-800 py-16">
          <p class="font-mono text-xs text-neutral-500 uppercase tracking-wider mb-4">
            Scale
          </p>
          <h2 class="text-2xl font-semibold text-neutral-50 mb-6">
            Scalable Blocks
          </h2>
          <div class="text-neutral-500 leading-relaxed space-y-4">
            <p>
              Unlike other blockchains with artificial block size limits, BSV has unbounded block sizes that scale with network demand.
            </p>
            <p>
              This enables:
            </p>
            <div class="border-t border-neutral-800">
              <div class="py-3 border-b border-neutral-800">
                <p class="text-sm text-neutral-400">
                  Massive transaction throughput (millions of transactions per block)
                </p>
              </div>
              <div class="py-3 border-b border-neutral-800">
                <p class="text-sm text-neutral-400">
                  Extremely low transaction fees (fractions of a cent)
                </p>
              </div>
              <div class="py-3 border-b border-neutral-800">
                <p class="text-sm text-neutral-400">
                  On-chain data storage and complex applications
                </p>
              </div>
              <div class="py-3 border-b border-neutral-800">
                <p class="text-sm text-neutral-400">
                  Global scale for enterprise and consumer applications
                </p>
              </div>
            </div>
            <p>
              BSV has proven this capability with multi-gigabyte blocks, demonstrating that blockchain can scale to meet real-world demands.
            </p>
          </div>
        </section>

        <%!-- Bitcoin Script Section --%>
        <section class="border-b border-neutral-800 py-16">
          <p class="font-mono text-xs text-neutral-500 uppercase tracking-wider mb-4">
            Programmability
          </p>
          <h2 class="text-2xl font-semibold text-neutral-50 mb-6">
            Bitcoin Script
          </h2>
          <div class="text-neutral-500 leading-relaxed space-y-4">
            <p>
              Bitcoin Script is the original smart contract language built into Bitcoin.
              It's a simple, stack-based programming language that defines the conditions under which bitcoins can be spent.
            </p>
            <p>
              BSV has restored the full power of Bitcoin Script by:
            </p>
            <div class="border-t border-neutral-800">
              <div class="py-3 border-b border-neutral-800">
                <p class="text-sm text-neutral-400">
                  Re-enabling originally disabled opcodes
                </p>
              </div>
              <div class="py-3 border-b border-neutral-800">
                <p class="text-sm text-neutral-400">
                  Removing arbitrary script size limitations
                </p>
              </div>
              <div class="py-3 border-b border-neutral-800">
                <p class="text-sm text-neutral-400">
                  Supporting complex smart contracts and logic
                </p>
              </div>
              <div class="py-3 border-b border-neutral-800">
                <p class="text-sm text-neutral-400">
                  Enabling tokens, NFTs, and sophisticated applications
                </p>
              </div>
            </div>
            <p>
              This makes BSV a powerful platform for building decentralized applications while maintaining Bitcoin's security model and simplicity.
            </p>
          </div>
        </section>

        <%!-- Support Section --%>
        <section class="border-b border-neutral-800 py-16">
          <p class="font-mono text-xs text-neutral-500 uppercase tracking-wider mb-4">
            Support
          </p>
          <h2 class="text-2xl font-semibold text-neutral-50 mb-6">
            Support This Project
          </h2>
          <p class="text-neutral-500 leading-relaxed mb-8">
            Bitblocks is an open-source project built by the community, for the community.
            If you find this explorer useful, please consider supporting us:
          </p>

          <div class="space-y-6">
            <a
              href="https://github.com/afomi/bitblocks"
              target="_blank"
              rel="noopener noreferrer"
              class="inline-flex items-center gap-2 px-6 py-3 bg-surface-raised text-neutral-50 border border-neutral-700 rounded hover:bg-surface-overlay transition-colors font-medium"
            >
              <svg
                xmlns="http://www.w3.org/2000/svg"
                fill="currentColor"
                viewBox="0 0 24 24"
                class="size-5"
              >
                <path d="M12 0c-6.626 0-12 5.373-12 12 0 5.302 3.438 9.8 8.207 11.387.599.111.793-.261.793-.577v-2.234c-3.338.726-4.033-1.416-4.033-1.416-.546-1.387-1.333-1.756-1.333-1.756-1.089-.745.083-.729.083-.729 1.205.084 1.839 1.237 1.839 1.237 1.07 1.834 2.807 1.304 3.492.997.107-.775.418-1.305.762-1.604-2.665-.305-5.467-1.334-5.467-5.931 0-1.311.469-2.381 1.236-3.221-.124-.303-.535-1.524.117-3.176 0 0 1.008-.322 3.301 1.23.957-.266 1.983-.399 3.003-.404 1.02.005 2.047.138 3.006.404 2.291-1.552 3.297-1.23 3.297-1.23.653 1.653.242 2.874.118 3.176.77.84 1.235 1.911 1.235 3.221 0 4.609-2.807 5.624-5.479 5.921.43.372.823 1.102.823 2.222v3.293c0 .319.192.694.801.576 4.765-1.589 8.199-6.086 8.199-11.386 0-6.627-5.373-12-12-12z" />
              </svg>
              Star on GitHub
            </a>

            <div class="bg-surface-raised rounded p-6">
              <p class="text-sm font-semibold text-neutral-50 mb-2">
                Donate BSV
              </p>
              <p class="text-sm text-neutral-500 mb-3">
                Support development with a BSV donation:
              </p>
              <div class="bg-surface-overlay p-3 rounded">
                <code class="text-xs font-mono text-neutral-400 break-all">
                  [BSV_ADDRESS_HERE]
                </code>
              </div>
              <p class="font-mono text-xs text-neutral-500 mt-3">
                Click to copy address
              </p>
            </div>
          </div>
        </section>

        <%!-- Additional Links --%>
        <section class="py-16">
          <h2 class="text-2xl font-semibold text-neutral-50 mb-6">
            Learn More
          </h2>
          <div class="border-t border-neutral-800">
            <a
              href="https://wiki.bitcoinsv.io/"
              target="_blank"
              rel="noopener noreferrer"
              class="flex items-center justify-between py-4 border-b border-neutral-800 group"
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
              class="flex items-center justify-between py-4 border-b border-neutral-800 group"
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
              class="flex items-center justify-between py-4 border-b border-neutral-800 group"
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
    """
  end
end
