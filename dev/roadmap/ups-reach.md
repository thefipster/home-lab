# Task: The rest of the load on the UPS

Goal: the on-battery alert can leave the house. The shutdown chain is drilled
end to end — on-battery notification, backstop, guests down together, killpower,
and the lab booting itself when mains returned
([ups-power-cut-drill.md](../../docs/drills/ups-power-cut-drill.md)) — but only
the server is plugged into the UPS. The router, the switch and the WAN
termination are what carry an ntfy notification out, so a real outage today
shuts the lab down **correctly and silently**.

## The work

- **Measure before plugging in.** The added draw of router, switch and WAN
  termination shortens the battery runtime that
  [proxmox-setup.md Part 10](../../docs/guides/proxmox-setup.md#part-10--survive-a-power-cut)'s
  backstop timing was calibrated against — recheck that the shutdown still
  completes with margin at the new load.
- **Plug them in**, and update Part 10's description of what is on the UPS.
- **Re-run the on-battery half of the drill** with the network powered, and
  confirm the notification actually arrives on a phone — which it does only
  while the ISP's side of the WAN is itself up; state that honestly in the
  drill rather than implying the alert is unconditional.

## Recommendation

This is a hardware errand more than repo work — the repo-visible part is the
runtime re-check, the drill re-run and the Part 10 update. It is also the only
open task that makes an *existing, drilled* mechanism actually reach a human,
which is a rare ratio of value to effort; nothing blocks it and nothing depends
on it, so it can happen whenever the cables and an hour coincide.
