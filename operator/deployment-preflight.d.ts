import type { Address, OperatorManifest } from "./index.js";
export interface PortfolioDeploymentReader {
  chainId(): Promise<number>;
  coordinatorMarketCount(address: Address): Promise<number>;
  policyMarketCount(address: Address): Promise<number>;
  coordinatorMarket(address: Address, index: number): Promise<{ core: Address; gateway: Address }>;
  policyMarketCore(address: Address, index: number): Promise<Address>;
  coordinatorPolicy(address: Address): Promise<Address>;
  coordinatorVault(address: Address): Promise<Address>;
  policySharedCollateralVault(address: Address): Promise<Address>;
  vaultController(address: Address): Promise<Address>;
  vaultCollateralToken(address: Address): Promise<Address>;
  corePortfolioController(address: Address): Promise<Address>;
  coreAdvancedModule(address: Address): Promise<Address>;
  gatewayCore(address: Address): Promise<Address>;
  gatewayPortfolioController(address: Address): Promise<Address>;
  gatewayPortfolioMarketIndex(address: Address): Promise<number>;
}
export declare function verifyPortfolioDeployment(
  input: OperatorManifest, reader: PortfolioDeploymentReader,
): Promise<void>;
