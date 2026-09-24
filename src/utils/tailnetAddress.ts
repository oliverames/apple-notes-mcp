/**
 * Find this Mac's Tailscale IPv4 address for the template editor's opt-in
 * `--tailnet` mode.
 *
 * Tailscale gives each device an address in the carrier-grade NAT range
 * 100.64.0.0/10 on a `utun` interface. This scans the network interfaces
 * only: it never runs the tailscale CLI and never reads or changes Tailscale
 * settings, serve or funnel configuration, or the firewall.
 *
 * @module utils/tailnetAddress
 */
import { networkInterfaces, type NetworkInterfaceInfo } from "node:os";

/** True for an IPv4 address in 100.64.0.0/10. */
export function isTailnetIPv4(address: string): boolean {
  const match = /^100\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(address);
  if (!match) return false;
  const [second, third, fourth] = match.slice(1).map(Number);
  return second >= 64 && second <= 127 && third <= 255 && fourth <= 255;
}

/**
 * The first 100.64.0.0/10 IPv4 address on a non-internal interface, preferring
 * `utun*` interfaces, or undefined when there is none.
 */
export function findTailnetAddress(
  interfaces: NodeJS.Dict<NetworkInterfaceInfo[]> = networkInterfaces()
): { address: string; interface: string } | undefined {
  const candidates: Array<{ address: string; interface: string }> = [];
  for (const [name, infos] of Object.entries(interfaces)) {
    for (const info of infos ?? []) {
      if (info.family === "IPv4" && !info.internal && isTailnetIPv4(info.address))
        candidates.push({ address: info.address, interface: name });
    }
  }
  return candidates.find((c) => c.interface.startsWith("utun")) ?? candidates[0];
}
