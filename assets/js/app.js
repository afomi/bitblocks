// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import topbar from "../vendor/topbar"
import {polyfillInvokerCommands} from "./lib/invoker_commands"

// Import hooks
import TxChart from "./hooks/tx_chart"
import IOChart from "./hooks/io_chart"
import SatoshiFlowChart from "./hooks/satoshi_flow_chart"
import BlockTimeChart from "./hooks/block_time_chart"
import BlockSizeChart from "./hooks/block_size_chart"
import TransactionGraph from "./hooks/transaction_graph"
import ForkGraph from "./hooks/fork_graph"
import BlockGraph from "./hooks/block_graph"
import PeerMap from "./hooks/peer_map"
import NetworkPulse from "./hooks/network_pulse"
import EcosystemGraph from "./hooks/ecosystem_graph"
import ChainScrubber from "./hooks/chain_scrubber"
import TxFlow from "./hooks/tx_flow"

let Hooks = {
  TxChart: TxChart,
  IOChart: IOChart,
  SatoshiFlowChart: SatoshiFlowChart,
  BlockTimeChart: BlockTimeChart,
  BlockSizeChart: BlockSizeChart,
  TransactionGraph: TransactionGraph,
  ForkGraph: ForkGraph,
  BlockGraph: BlockGraph,
  PeerMap: PeerMap,
  NetworkPulse: NetworkPulse,
  EcosystemGraph: EcosystemGraph,
  ChainScrubber: ChainScrubber,
  TxFlow: TxFlow
}

let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
let liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: Hooks
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// Copy buttons (BitblocksWeb.MultisigComponents.copy_button): the text to
// copy rides in the event's detail. The button reads "Copied" or "Couldn't
// copy" for a moment, and the live region beside it says so to a screen
// reader.
window.addEventListener("bitblocks:copy", event => {
  const button = event.target
  const label = button.querySelector("[data-copy-label]")
  const status = document.getElementById(`${button.id}-status`)
  const show = (shown, spoken) => {
    if (label) label.textContent = shown
    if (status) status.textContent = spoken
    setTimeout(() => {
      if (label) label.textContent = "Copy"
      if (status) status.textContent = ""
    }, 2000)
  }
  const failed = () => show("Couldn't copy", `Couldn't copy ${event.detail.label}`)
  if (!navigator.clipboard) return failed()
  navigator.clipboard.writeText(event.detail.text)
    .then(() => show("Copied", `Copied ${event.detail.label}`), failed)
})

// connect if there are any LiveViews on the page
liveSocket.connect()

polyfillInvokerCommands()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket
