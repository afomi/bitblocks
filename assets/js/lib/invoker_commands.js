// The header's phone menu opens with the Invoker Commands API:
// <button command="show-modal" commandfor="mobile-menu"> and command="close".
// Browsers without it (older Safari on iPhone) get the same two commands
// here, so the menu button never does nothing.
export function polyfillInvokerCommands() {
  if ("commandForElement" in HTMLButtonElement.prototype) return

  document.addEventListener("click", (event) => {
    const button = event.target.closest("button[command][commandfor]")
    if (!button) return

    const target = document.getElementById(button.getAttribute("commandfor"))
    if (!(target instanceof HTMLDialogElement)) return

    const command = button.getAttribute("command")
    if (command === "show-modal" && !target.open) target.showModal()
    if (command === "close" && target.open) target.close()
  })
}
