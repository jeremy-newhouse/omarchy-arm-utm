#!/usr/bin/env python3
"""Re-embeds provision/src/* into the __PAYLOAD_*__ heredocs in build-omarchy-arm.sh."""
import os
ROOT=os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MAP={
 "__PAYLOAD_PROVISION_STAGE1_SH__":"provision/src/stage1.sh",
 "__PAYLOAD_PROVISION_STAGE2_SH__":"provision/src/stage2.sh",
 "__PAYLOAD_PROVISION_STAGE3_SH__":"provision/src/stage3.sh",
 "__PAYLOAD_PROVISION_REPAIR_SH__":"provision/src/repair.sh",
 "__PAYLOAD_PROVISION_SANITIZE_SH__":"provision/src/sanitize.sh",
 "__PAYLOAD_PROVISION_EXTRAS_SH__":"provision/src/omarchy-arm-extras",
 "__PAYLOAD_PROVISION_CLIPBRD_SH__":"provision/src/omarchy-arm-clipboard",
 "__PAYLOAD_PROVISION_VDAGENT_PY__":"provision/src/omarchy-arm-vdagent",
 "__PAYLOAD_PROVISION_SHARE_SH__":"provision/src/omarchy-arm-share",
 "__PAYLOAD_PROVISION_README_MD__":"provision/src/README.md",
 "__PAYLOAD_PROVISION_ARMSYNC_SH__":"provision/src/hooks/10-arm-sync",
 "__PAYLOAD_SCRIPTS_BUILD_EXP__":"scripts/build.exp",
 "__PAYLOAD_SCRIPTS_REPAIR_EXP__":"scripts/repair.exp",
 "__PAYLOAD_SCRIPTS_MAKE-UTM_SH__":"scripts/make-utm.sh",

}
p=os.path.join(ROOT,"build-omarchy-arm.sh")
lines=open(p).read().split("\n")
changes=0
for marker,rel in MAP.items():
    ini=next((i for i,l in enumerate(lines) if l.rstrip().endswith("<<'%s'"%marker)), None)
    if ini is None: print(f"  !! no opening tag: {marker}"); continue
    end=next(j for j in range(ini+1,len(lines)) if lines[j]==marker)
    new=open(os.path.join(ROOT,rel)).read().rstrip("\n").split("\n")
    if lines[ini+1:end]==new: continue
    lines[ini+1:end]=new
    changes+=1
    print(f"  re-embedded {os.path.basename(rel)} ({len(new)} lines)")
open(p,"w").write("\n".join(lines))
print(f"  {changes} payload(s) updated" if changes else "  everything was already in sync")

# A payload with no entry in MAP is a file nobody re-syncs: edit the source,
# nothing happens, and the builder keeps deploying the old copy.
import re
all_markers=set(re.findall(r"<<'(__PAYLOAD_[A-Z0-9_.-]+__)'", "\n".join(lines)))
orphans=sorted(all_markers - set(MAP))
if orphans:
    print("  no declared source (its source of truth is the payload itself):")
    for h in orphans: print(f"    {h}")
