# # execute
nargo execute ./claim/claim.gz --package claim 
nargo execute ./withdrawOrTransfer/withdrawOrTransfer.gz --package withdrawOrTransfer 


# # prove
bb prove -b ./target/claim/claim.json -w ./target/claim/claim.gz -o ./target/claim --oracle_hash keccak --output_format bytes_and_fields
bb prove -b ./target/withdrawOrTransfer/withdrawOrTransfer.json -w ./target/withdrawOrTransfer/withdrawOrTransfer.gz -o ./target/withdrawOrTransfer --oracle_hash keccak --output_format bytes_and_fields

# save proofs in hex to a file
(echo -n "0x"; cat ./target/claim/proof | od -An -v -t x1 | tr -d $' \n') > ./target/claim/proof.hex
(echo -n "0x"; cat ./target/withdrawOrTransfer/proof | od -An -v -t x1 | tr -d $' \n') > ./target/withdrawOrTransfer/proof.hex