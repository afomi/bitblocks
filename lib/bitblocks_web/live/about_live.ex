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
    <div
      class="container mx-auto px-4 py-8 max-w-4xl"
    >
      <h1
        class="text-4xl font-bold mb-8 text-gray-900 dark:text-white"
      >
        About Bitblocks
      </h1>

      <%!-- Introduction --%>
      <div
        class="bg-white dark:bg-gray-800 shadow-md rounded-lg p-6 mb-6"
      >
        <p
          class="text-lg text-gray-700 dark:text-gray-300 mb-4"
        >
          Bitblocks is a Bitcoin SV blockchain explorer that provides real-time access to blocks, transactions, and protocol data on the BSV network.
        </p>
        <p
          class="text-gray-700 dark:text-gray-300"
        >
          We're building tools to make the Bitcoin SV blockchain more accessible and easier to understand for developers, researchers, and enthusiasts.
        </p>
      </div>

      <%!-- Bitcoin SV Section --%>
      <div
        class="bg-white dark:bg-gray-800 shadow-md rounded-lg p-6 mb-6"
      >
        <h2
          class="text-2xl font-bold mb-4 text-gray-900 dark:text-white flex items-center gap-2"
        >
          <svg
            xmlns="http://www.w3.org/2000/svg"
            fill="none"
            viewBox="0 0 24 24"
            stroke-width="1.5"
            stroke="currentColor"
            class="size-6 text-orange-500"
          >
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              d="M12 6v12m-3-2.818.879.659c1.171.879 3.07.879 4.242 0 1.172-.879 1.172-2.303 0-3.182C13.536 12.219 12.768 12 12 12c-.725 0-1.45-.22-2.003-.659-1.106-.879-1.106-2.303 0-3.182s2.9-.879 4.006 0l.415.33M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0Z"
            />
          </svg>
          Bitcoin SV
        </h2>
        <p
          class="text-gray-700 dark:text-gray-300 mb-3"
        >
          Bitcoin SV (Satoshi Vision) is the original Bitcoin protocol, restored and stabilized to fulfill Satoshi Nakamoto's vision of peer-to-peer electronic cash.
        </p>
        <p
          class="text-gray-700 dark:text-gray-300"
        >
          BSV maintains Bitcoin's fundamental design while removing artificial limitations, enabling massive on-chain scaling and unlimited possibilities for applications.
        </p>
      </div>

      <%!-- Scalable Blocks Section --%>
      <div
        class="bg-white dark:bg-gray-800 shadow-md rounded-lg p-6 mb-6"
      >
        <h2
          class="text-2xl font-bold mb-4 text-gray-900 dark:text-white flex items-center gap-2"
        >
          <svg
            xmlns="http://www.w3.org/2000/svg"
            fill="none"
            viewBox="0 0 24 24"
            stroke-width="1.5"
            stroke="currentColor"
            class="size-6 text-blue-500"
          >
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              d="m21 7.5-9-5.25L3 7.5m18 0-9 5.25m9-5.25v9l-9 5.25M3 7.5l9 5.25M3 7.5v9l9 5.25m0-9v9"
            />
          </svg>
          Scalable Blocks
        </h2>
        <p
          class="text-gray-700 dark:text-gray-300 mb-3"
        >
          Unlike other blockchains with artificial block size limits, BSV has unbounded block sizes that scale with network demand.
        </p>
        <p
          class="text-gray-700 dark:text-gray-300 mb-3"
        >
          This enables:
        </p>
        <ul
          class="list-disc list-inside text-gray-700 dark:text-gray-300 space-y-2 mb-3"
        >
          <li>
            Massive transaction throughput (millions of transactions per block)
          </li>
          <li>
            Extremely low transaction fees (fractions of a cent)
          </li>
          <li>
            On-chain data storage and complex applications
          </li>
          <li>
            Global scale for enterprise and consumer applications
          </li>
        </ul>
        <p
          class="text-gray-700 dark:text-gray-300"
        >
          BSV has proven this capability with multi-gigabyte blocks, demonstrating that blockchain can scale to meet real-world demands.
        </p>
      </div>

      <%!-- Bitcoin Script Section --%>
      <div
        class="bg-white dark:bg-gray-800 shadow-md rounded-lg p-6 mb-6"
      >
        <h2
          class="text-2xl font-bold mb-4 text-gray-900 dark:text-white flex items-center gap-2"
        >
          <svg
            xmlns="http://www.w3.org/2000/svg"
            fill="none"
            viewBox="0 0 24 24"
            stroke-width="1.5"
            stroke="currentColor"
            class="size-6 text-green-500"
          >
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              d="M17.25 6.75 22.5 12l-5.25 5.25m-10.5 0L1.5 12l5.25-5.25m7.5-3-4.5 16.5"
            />
          </svg>
          Bitcoin Script
        </h2>
        <p
          class="text-gray-700 dark:text-gray-300 mb-3"
        >
          Bitcoin Script is the original smart contract language built into Bitcoin.
          It's a simple, stack-based programming language that defines the conditions under which bitcoins can be spent.
        </p>
        <p
          class="text-gray-700 dark:text-gray-300 mb-3"
        >
          BSV has restored the full power of Bitcoin Script by:
        </p>
        <ul
          class="list-disc list-inside text-gray-700 dark:text-gray-300 space-y-2 mb-3"
        >
          <li>
            Re-enabling originally disabled opcodes
          </li>
          <li>
            Removing arbitrary script size limitations
          </li>
          <li>
            Supporting complex smart contracts and logic
          </li>
          <li>
            Enabling tokens, NFTs, and sophisticated applications
          </li>
        </ul>
        <p
          class="text-gray-700 dark:text-gray-300"
        >
          This makes BSV a powerful platform for building decentralized applications while maintaining Bitcoin's security model and simplicity.
        </p>
      </div>

      <%!-- Support Section --%>
      <div
        class="bg-gradient-to-r from-orange-50 to-blue-50 dark:from-gray-800 dark:to-gray-700 shadow-md rounded-lg p-6 mb-6 border-2 border-orange-200 dark:border-orange-900"
      >
        <h2
          class="text-2xl font-bold mb-4 text-gray-900 dark:text-white flex items-center gap-2"
        >
          <svg
            xmlns="http://www.w3.org/2000/svg"
            fill="none"
            viewBox="0 0 24 24"
            stroke-width="1.5"
            stroke="currentColor"
            class="size-6 text-red-500"
          >
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              d="M21 8.25c0-2.485-2.099-4.5-4.688-4.5-1.935 0-3.597 1.126-4.312 2.733-.715-1.607-2.377-2.733-4.313-2.733C5.1 3.75 3 5.765 3 8.25c0 7.22 9 12 9 12s9-4.78 9-12Z"
            />
          </svg>
          Support This Project
        </h2>
        <p
          class="text-gray-700 dark:text-gray-300 mb-4"
        >
          Bitblocks is an open-source project built by the community, for the community.
          If you find this explorer useful, please consider supporting us:
        </p>

        <div
          class="space-y-4"
        >
          <%!-- GitHub Star --%>
          <div
            class="flex items-center gap-4"
          >
            <a
              href="https://github.com/afomi/bitblocks"
              target="_blank"
              rel="noopener noreferrer"
              class="inline-flex items-center gap-2 px-6 py-3 bg-gray-900 dark:bg-gray-700 text-white rounded-lg hover:bg-gray-800 dark:hover:bg-gray-600 transition-colors font-semibold shadow-sm"
            >
              <svg
                xmlns="http://www.w3.org/2000/svg"
                fill="currentColor"
                viewBox="0 0 24 24"
                class="size-5"
              >
                <path
                  d="M12 0c-6.626 0-12 5.373-12 12 0 5.302 3.438 9.8 8.207 11.387.599.111.793-.261.793-.577v-2.234c-3.338.726-4.033-1.416-4.033-1.416-.546-1.387-1.333-1.756-1.333-1.756-1.089-.745.083-.729.083-.729 1.205.084 1.839 1.237 1.839 1.237 1.07 1.834 2.807 1.304 3.492.997.107-.775.418-1.305.762-1.604-2.665-.305-5.467-1.334-5.467-5.931 0-1.311.469-2.381 1.236-3.221-.124-.303-.535-1.524.117-3.176 0 0 1.008-.322 3.301 1.23.957-.266 1.983-.399 3.003-.404 1.02.005 2.047.138 3.006.404 2.291-1.552 3.297-1.23 3.297-1.23.653 1.653.242 2.874.118 3.176.77.84 1.235 1.911 1.235 3.221 0 4.609-2.807 5.624-5.479 5.921.43.372.823 1.102.823 2.222v3.293c0 .319.192.694.801.576 4.765-1.589 8.199-6.086 8.199-11.386 0-6.627-5.373-12-12-12z"
                />
              </svg>
              Star on GitHub
            </a>
            <span
              class="text-sm text-gray-600 dark:text-gray-400"
            >
              Show your support and help us grow!
            </span>
          </div>

          <%!-- BSV Donation --%>
          <div
            class="bg-white dark:bg-gray-800 rounded-lg p-4 border border-gray-200 dark:border-gray-700"
          >
            <div
              class="flex items-center gap-2 mb-2"
            >
              <svg
                xmlns="http://www.w3.org/2000/svg"
                fill="none"
                viewBox="0 0 24 24"
                stroke-width="1.5"
                stroke="currentColor"
                class="size-5 text-orange-500"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  d="M12 6v12m-3-2.818.879.659c1.171.879 3.07.879 4.242 0 1.172-.879 1.172-2.303 0-3.182C13.536 12.219 12.768 12 12 12c-.725 0-1.45-.22-2.003-.659-1.106-.879-1.106-2.303 0-3.182s2.9-.879 4.006 0l.415.33M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0Z"
                />
              </svg>
              <span
                class="font-semibold text-gray-900 dark:text-white"
              >
                Donate BSV
              </span>
            </div>
            <p
              class="text-sm text-gray-600 dark:text-gray-400 mb-2"
            >
              Support development with a BSV donation:
            </p>
            <div
              class="bg-gray-50 dark:bg-gray-900 p-3 rounded border border-gray-200 dark:border-gray-700"
            >
              <code
                class="text-xs font-mono break-all text-gray-800 dark:text-gray-200"
              >
                [BSV_ADDRESS_HERE]
              </code>
            </div>
            <p
              class="text-xs text-gray-500 dark:text-gray-500 mt-2"
            >
              Click to copy address • All donations support continued development
            </p>
          </div>
        </div>
      </div>

      <%!-- Additional Links --%>
      <div
        class="bg-white dark:bg-gray-800 shadow-md rounded-lg p-6"
      >
        <h2
          class="text-xl font-bold mb-4 text-gray-900 dark:text-white"
        >
          Learn More
        </h2>
        <ul
          class="space-y-2"
        >
          <li>
            <a
              href="https://wiki.bitcoinsv.io/"
              target="_blank"
              rel="noopener noreferrer"
              class="text-blue-600 dark:text-blue-400 hover:underline"
            >
              Bitcoin SV Wiki →
            </a>
          </li>
          <li>
            <a
              href="https://bitcoinsv.com/"
              target="_blank"
              rel="noopener noreferrer"
              class="text-blue-600 dark:text-blue-400 hover:underline"
            >
              BitcoinSV.com →
            </a>
          </li>
          <li>
            <a
              href="https://github.com/afomi/bitblocks"
              target="_blank"
              rel="noopener noreferrer"
              class="text-blue-600 dark:text-blue-400 hover:underline"
            >
              Bitblocks on GitHub →
            </a>
          </li>
        </ul>
      </div>
    </div>
    """
  end
end
