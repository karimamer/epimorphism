#!/usr/bin/env bash
echo "Bundling Libraries"
for each in lib/sections/*.slib; do cat $each; printf "\n\n\n"; done > lib/sections.slib
for each in lib/core/*.lib; do cat $each; printf "\n\n\n"; done > lib/core.lib
for each in lib/core/**/*.lib; do cat $each; printf "\n\n\n"; done >> lib/core.lib
for each in lib/user/*.lib; do cat $each; printf "\n\n\n"; done > lib/user.lib
#for each in lib/user/**/*.lib; do cat $each; printf "\n\n\n"; done >> lib/user.lib
#printf "\n\n\n" >> lib/modules.lib
#for each in lib/modules/save/*.lib; do cat $each; printf "\n\n\n"; done >> lib/modules.lib
