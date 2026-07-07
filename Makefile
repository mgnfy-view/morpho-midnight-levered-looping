-include .env

all : install fbuild

install :; forge soldeer install

update :; forge soldeer update

format :; forge fmt

compile :; forge compile

fbuild :; forge build

ftest :; forge test

snapshot :; forge snapshot

deploy-callback-simulate :; forge script script/DeployMidnightLeverageCallback.s.sol \
	--rpc-url $(RPC_URL) \
	-vvvv

deploy-callback-broadcast :; forge script script/DeployMidnightLeverageCallback.s.sol \
	--rpc-url $(RPC_URL) \
	--broadcast \
	--verify \
	--verifier-url $(VERIFIER_URL) \
	--etherscan-api-key $(ETHERSCAN_V2_API_KEY) \
	-vvvv

anvil :; anvil -m 'test test test test test test test test test test test junk' --steps-tracing --block-time 1
