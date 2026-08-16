# UPS power-cut drill

**Runs on:** the Proxmox host — a recurring drill, not a build step

**Prerequisite:** [proxmox-setup.md Part 10](../guides/proxmox-setup.md#part-10--survive-a-power-cut)
complete — NUT running, the backstop timer set, the killpower dry run passing,
and the Kuma push wired.

Two things in the shutdown chain cannot be settled by reading. The **runtime**
figure does not come from the datasheet — it depends on this lab's actual load,
and it is the input to
[step 4's arithmetic](../guides/proxmox-setup.md#4-decide-when-to-shut-down).
**Killpower** is worse: it is the half most likely to be silently broken, and
its failure mode is a box that stays dark after an outage it appeared to
survive.

So this drill pulls the mains plug on purpose and watches the whole chain run.
**Re-run it when the battery is replaced**, and whenever equipment joins the
UPS — both change the measured runtime the arithmetic depends on.

## Before you pull the plug

Four parts of Part 10 can only fail during an outage, and each has a way to be
tested without one. Run all four first — they are listed, with why each is
written the way it is, in
[step 6's pre-flight box](../guides/proxmox-setup.md#6-report-ups-state-to-kuma-and-prometheus):
the signal the backstop sends, the push the event path makes, that the push
actually **notifies**, and killpower's `upsdrvctl -t shutdown` dry run.

A drill that fails on one of those tells you nothing you could not have learned
more cheaply.

## The drill

Pull the mains plug on the UPS and watch for all six of these:

1. The on-battery push arrives on your phone within seconds.
2. The backstop fires at 300 s.
3. All three guests shut down **together** — they share one `order`, so this is
   one 90-second window rather than three.
4. The host halts.
5. The UPS cuts its output, about 20 seconds later — that is
   `ups.delay.shutdown`, not a stall.
6. Plug mains back in. The UPS restores output, the board powers on, and Proxmox
   starts all three guests together.

Watch the first three from a shell before you lose it:

```bash
journalctl -fu nut-monitor
```

And note what the UPS thought it had left, which is the number this drill exists
to produce:

```bash
upsc ups battery.runtime
```

## What it produces

**Two outputs.** The **measured runtime**, which goes back into
[step 4](../guides/proxmox-setup.md#4-decide-when-to-shut-down) if
`300 + 270 < measured` no longer holds — and proof that the lab comes back
without you.

Re-run it when the battery is replaced, for the same reason
[backup-restore-drill.md](backup-restore-drill.md) is re-run yearly: a path
nobody has exercised is a hypothesis, not a capability.

## Still unproven by this drill

**The alert leaving the house.** Only the server is on the UPS today. The UDR,
the switch and the WAN termination are what let the on-battery notification
reach you during a real outage — until they are on it, this drill passes while a
genuine power cut shuts the lab down correctly and **silently**. The drill runs
with you standing beside the machine, which is exactly the condition that hides
this gap.

## Troubleshooting

The failure modes of the chain this drill exercises — a driver that will not
connect, a backstop that does not fire, a push that never arrives, a host that
stays dark — are all in
[Troubleshooting Part 10](../guides/proxmox-setup.md#troubleshooting-part-10),
beside the configuration that causes them.

## Next

Back to [proxmox-setup.md Part 10](../guides/proxmox-setup.md#part-10--survive-a-power-cut)
for the configuration this drill tests, or
[backup-restore-drill.md](backup-restore-drill.md) for the lab's other recurring
drill.
