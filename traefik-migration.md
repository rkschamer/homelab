Phase 1: Install Traefik in cluster

Add Traefik manifests under Flux, for example in a new folder such as flux/ingress or flux/infrastructure/traefik.
Create namespace traefik and label it with network-zone dmz, otherwise your namespace admission policy will block it.
Use HelmRelease with Service type LoadBalancer and pin 192.168.123.21.
Add network policy allows for Traefik to reach each backend namespace you migrate.
Example checks after deploy:

Expected:

Traefik service shows EXTERNAL-IP 192.168.123.21.
Speaker logs no fresh memberlist join errors.
Phase 2: Validate MetalLB and ingress path before cutover

Confirm VIP assignment:
Confirm MetalLB health:
Test from home LAN directly to VIP:
Use curl and app checks, not ping, as primary readiness signal.

Phase 3: Certificate strategy while running two Traefik instances

You have two valid options.

Option A (recommended): Transfer existing Traefik certificate store

Export old Docker Traefik acme storage file.
Import it as Kubernetes secret or mounted file in new Traefik.
New Traefik starts with existing certs, avoiding immediate re-issuance.
Important:

Do not let both instances renew the same domains at the same time for long.
During overlap, keep old Traefik handling public traffic; set new one to use imported certs for testing.
After cutover, disable or retire old Traefik renewals.
Option B: Re-issue certs on new cluster

Prefer DNS challenge.
Allows cert issuance before router cutover.
Cleaner long term, but requires DNS provider API setup and secrets.
If you stay with HTTP challenge:

New Traefik cannot complete challenge until Fritzbox points 80/443 to cluster VIP.
Phase 4: Dual-Traefik app migration pattern

Per application:

Deploy app in Kubernetes with internal ingress route on new Traefik.
Validate via hosts override or internal DNS pointing domain to 192.168.123.21.
Sync data from old Docker volume to Kubernetes PVC.
Freeze old app writes.
Final sync.
Flip route:
Either move domain DNS target to Fritzbox public IP that forwards to new VIP, or
Update Fritzbox forwarding to new endpoint if that is your model.
Validate externally.
Decommission old app from compose.
Phase 5: Final cutover

Switch Fritzbox 80/443 target to 192.168.123.21.
Monitor:
Keep old VM in standby for rollback window.
