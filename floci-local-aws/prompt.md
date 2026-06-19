Ok i was able to make it work by manually changing serverIP and Port of the asset data in the 3 assets, cloud, fam bucket log, and fam bucket data
Undo what you just did as its unecessary and i just tested the latest version
add to [04-show-fam-asset-info.sh](fam/04-show-fam-asset-info.sh) the instructions below, feel free to make a better wording

``` log
FAM Form UI does not support changing default AWS URL
Go to Discover -> Asset Index Pattern
Search for your FAM Assets
Update each document fields
 - Server Type
 - Server Port
 - Service Endpoints
 
 Make sure that they contain the actual Floci Server IP and Ports running CloudTrail Service
```