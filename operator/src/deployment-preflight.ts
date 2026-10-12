import { validateOperatorManifest, type Address, type OperatorManifest } from "./index.js";

/**
 * Integrator-supplied authoritative on-chain reads, preferably pinned to one
 * finalized block. Implement with the deployment's verified ABIs and RPC.
 */
export interface PortfolioDeploymentReader {
  chainId(): Promise<number>;
  coordinatorMarketCount(address: Address): Promise<number>;
  policyMarketCount(address: Address): Promise<number>;
  coordinatorMarket(address: Address, index: number): Promise<{ core: Address; gateway: Address }>;
  policyMarketCore(address: Address, index: number): Promise<Address>;
  coordinatorPolicy(address: Address): Promise<Address>;
  coordinatorVault(address: Address): Promise<Address>;
  policySharedCollateralVault(address: Address): Promise<Address>;
}

const sameAddress = (left: string, right: string) => left.toLowerCase() === right.toLowerCase();

/**
 * Refuses bootstrapping against the wrong market tuple, collateral vault,
 * margin policy or chain. It does not host RPC or decode deployment ABIs.
 */
export async function verifyPortfolioDeployment(
  input: OperatorManifest,
  reader: PortfolioDeploymentReader,
): Promise<void> {
  const manifest = validateOperatorManifest(input);
  if (!manifest.portfolio) throw new Error("portfolio deployment verification requires portfolio manifest");
  const portfolio = manifest.portfolio;
  if (await reader.chainId() !== manifest.chainId) throw new Error("portfolio deployment chain mismatch");
  const [coordinatorCount, policyCount, actualPolicy, actualVault, policyVault] = await Promise.all([
    reader.coordinatorMarketCount(portfolio.coordinator),
    reader.policyMarketCount(portfolio.policy),
    reader.coordinatorPolicy(portfolio.coordinator),
    reader.coordinatorVault(portfolio.coordinator),
    reader.policySharedCollateralVault(portfolio.policy),
  ]);
  if (coordinatorCount !== manifest.markets.length || policyCount !== manifest.markets.length) {
    throw new Error("portfolio on-chain market count mismatch");
  }
  if (!sameAddress(actualPolicy, portfolio.policy) ||
      !sameAddress(actualVault, portfolio.vault) ||
      !sameAddress(policyVault, portfolio.vault)) {
    throw new Error("portfolio on-chain policy or vault mismatch");
  }
  for (const market of manifest.markets) {
    const index = market.portfolioMarketIndex!;
    const [coordinatorMarket, policyCore] = await Promise.all([
      reader.coordinatorMarket(portfolio.coordinator, index),
      reader.policyMarketCore(portfolio.policy, index),
    ]);
    if (!sameAddress(coordinatorMarket.core, market.core) ||
        !sameAddress(coordinatorMarket.gateway, market.advanced) ||
        !sameAddress(policyCore, market.core)) {
      throw new Error("portfolio on-chain market tuple mismatch at index " + index);
    }
  }
}
