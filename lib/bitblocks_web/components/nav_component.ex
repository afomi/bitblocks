defmodule BitblocksWeb.NavComponent do
  use Phoenix.Component

  def nav(assigns) do
    assigns = assign(assigns, :dev_routes, dev_routes?())

    ~H"""
    <!-- Include this script tag or install `@tailwindplus/elements` via npm: -->
    <!-- <script src="https://cdn.jsdelivr.net/npm/@tailwindplus/elements@1" type="module"></script> -->
    <header class="bg-white dark:bg-gray-900">
      <nav
        aria-label="Global"
        class="mx-auto flex max-w-7xl items-center justify-between p-6 lg:px-8"
      >
        <div class="flex items-center gap-x-12">
          <a
            href="/"
            class="-m-1.5 p-1.5 flex items-center gap-2"
          >
            <svg
              xmlns="http://www.w3.org/2000/svg"
              fill="none"
              viewBox="0 0 24 24"
              stroke-width="1.5"
              stroke="currentColor"
              class="size-10 text-orange-500"
            >
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                d="m21 7.5-9-5.25L3 7.5m18 0-9 5.25m9-5.25v9l-9 5.25M3 7.5l9 5.25M3 7.5v9l9 5.25m0-9v9"
              />
            </svg>
            <span class="text-xl font-semibold text-gray-900 dark:text-white">Bitblocks</span>
          </a>
          <div class="hidden lg:flex lg:gap-x-12">
            <a href="/blocks" class="text-sm/6 font-semibold text-gray-900 dark:text-white">Blocks</a>
            <a href="/transactions" class="text-sm/6 font-semibold text-gray-900 dark:text-white">Transactions</a>
            <a href="/about" class="text-sm/6 font-semibold text-gray-900 dark:text-white">About</a>
          </div>
        </div>
        <div class="flex lg:hidden">
          <button
            type="button"
            command="show-modal"
            commandfor="mobile-menu"
            class="-m-2.5 inline-flex items-center justify-center rounded-md p-2.5 text-gray-700 dark:text-gray-400 dark:hover:text-white"
          >
            <span class="sr-only">Open main menu</span>
            <svg
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              stroke-width="1.5"
              data-slot="icon"
              aria-hidden="true"
              class="size-6"
            >
              <path
                d="M3.75 6.75h16.5M3.75 12h16.5m-16.5 5.25h16.5"
                stroke-linecap="round"
                stroke-linejoin="round"
              />
            </svg>
          </button>
        </div>
      </nav>
      <el-dialog>
        <dialog id="mobile-menu" class="m-0 p-0 backdrop:bg-transparent lg:hidden">
          <div tabindex="0" class="fixed inset-0 focus:outline focus:outline-0">
            <el-dialog-panel class="fixed inset-y-0 left-0 z-10 w-full overflow-y-auto bg-white px-6 py-6 dark:bg-gray-900">
              <div class="flex items-center justify-between">
                <a
                  href="/"
                  class="-m-1.5 p-1.5 flex items-center gap-2"
                >
                  <svg
                    xmlns="http://www.w3.org/2000/svg"
                    fill="none"
                    viewBox="0 0 24 24"
                    stroke-width="1.5"
                    stroke="currentColor"
                    class="size-10 text-orange-500"
                  >
                    <path
                      stroke-linecap="round"
                      stroke-linejoin="round"
                      d="m21 7.5-9-5.25L3 7.5m18 0-9 5.25m9-5.25v9l-9 5.25M3 7.5l9 5.25M3 7.5v9l9 5.25m0-9v9"
                    />
                  </svg>
                  <span class="text-xl font-semibold text-gray-900 dark:text-white">Bitblocks</span>
                </a>
                <button
                  type="button"
                  command="close"
                  commandfor="mobile-menu"
                  class="-m-2.5 rounded-md p-2.5 text-gray-700 dark:text-gray-400 dark:hover:text-white"
                >
                  <span class="sr-only">Close menu</span>
                  <svg
                    viewBox="0 0 24 24"
                    fill="none"
                    stroke="currentColor"
                    stroke-width="1.5"
                    data-slot="icon"
                    aria-hidden="true"
                    class="size-6"
                  >
                    <path
                      d="M6 18 18 6M6 6l12 12"
                      stroke-linecap="round"
                      stroke-linejoin="round"
                    />
                  </svg>
                </button>
              </div>
              <div class="mt-6 space-y-2">
                <a href="/blocks" class="-mx-3 block rounded-lg px-3 py-2 text-base/7 font-semibold text-gray-900 hover:bg-gray-50 dark:text-white dark:hover:bg-white/5">Blocks</a>
                <a href="/transactions" class="-mx-3 block rounded-lg px-3 py-2 text-base/7 font-semibold text-gray-900 hover:bg-gray-50 dark:text-white dark:hover:bg-white/5">Transactions</a>
                <a href="/about" class="-mx-3 block rounded-lg px-3 py-2 text-base/7 font-semibold text-gray-900 hover:bg-gray-50 dark:text-white dark:hover:bg-white/5">About</a>
              </div>
            </el-dialog-panel>
          </div>
        </dialog>
      </el-dialog>
    </header>
    """
  end

  defp dev_routes? do
    # Check if dev_routes is enabled (in dev/test environments)
    Application.get_env(:bitblocks, :dev_routes, false)
  end
end
