import { BigNumber, Signer, Wallet } from "ethers";
import { JsonRpcProvider, Provider } from "@ethersproject/providers";
import {
  GovernorQueueStage,
  ProposalStage,
  ProposalStageStatus,
  getProvider,
} from "./proposalStage";
import { StageFactory, TrackerEventName } from "./proposalPipeline";
import * as dotenv from "dotenv";
import * as fs from "fs";
dotenv.config();
import yargs from "yargs";
import { wait } from "./utils";
import * as path from "path";
import {
  GPMErrorEvent,
  GPMEvent,
  GnosisSafeProposalMonitor,
  GovernorProposalMonitor,
  ProposalMonitor,
} from "./proposalMonitor";

const ETH_KEY = process.env.ETH_KEY || "";
const ARB_KEY = process.env.ARB_KEY || "";

const options = yargs(process.argv.slice(2))
  .options({
    l1RpcUrl: { type: "string", demandOption: true },
    govChainRpcUrl: { type: "string", demandOption: true },
    novaRpcUrl: { type: "string", demandOption: true },
    coreGovernorAddress: { type: "string", demandOption: false },
    treasuryGovernorAddress: { type: "string", demandOption: false },
    sevenTwelveCouncilAddress: { type: "string", demandOption: false },
    startBlock: { type: "number", demandOption: false, default: 72559827 },
    pollingIntervalSeconds: { type: "number", demandOption: false, default: 300 },
    blockLag: { type: "number", demandOption: false, default: 5 },
    writeMode: { type: "boolean", demandOption: false, default: false },
    jsonOutputLocation: { type: "string", demandOption: false },
    proposalId: { type: "string", demandOption: false },
  })
  .parseSync() as {
  l1RpcUrl: string;
  govChainRpcUrl: string;
  novaRpcUrl: string;
  coreGovernorAddress?: string;
  treasuryGovernorAddress?: string;
  sevenTwelveCouncilAddress?: string;
  startBlock: number;
  pollingIntervalSeconds: number;
  blockLag: number;
  writeMode: boolean;
  proposalId?: string;
  jsonOutputLocation?: string;
};

const attachConsole = (proposalMonitor: ProposalMonitor, monitorName: string) => {
  proposalMonitor.on(TrackerEventName.TRACKER_STARTED, (e: GPMEvent) => {
    console.log(`${monitorName} tracker started:  Gov:${e.originAddress}, Stage:${e.identifier}`);
  });

  proposalMonitor.on(TrackerEventName.TRACKER_ENDED, (e: GPMEvent) => {
    console.log(`${monitorName} tracker ended:  Gov:${e.originAddress}, Prop:${e.identifier}`);
  });

  proposalMonitor.on(TrackerEventName.TRACKER_ERRORED, (e: GPMErrorEvent) => {
    console.log(
      `${monitorName} tracker errored:  Gov:${e.originAddress}, Prop:${e.identifier} Stage:${
        e.stage
      } Status:${ProposalStageStatus[e.status]} Error: ${e.error}`
    );
  });
  proposalMonitor.on(TrackerEventName.TRACKER_STATUS, (e: GPMEvent) => {
    console.log(
      `${monitorName} status update:  Gov:${e.originAddress}, Prop:${e.identifier}  Stage:${
        e.stage
      } Status:${ProposalStageStatus[e.status]}`
    );
  });
};

const startMonitor = async (
  monitorName: string,
  monitor: ProposalMonitor,
  jsonLogger?: JsonLogger,
  proposalId?: string
) => {
  attachConsole(monitor, monitorName);

  if (jsonLogger) {
    jsonLogger.subscribeToMonitor(monitor);
  }
  if (proposalId) {
    const receipts = await monitor.getOriginReceipts(options.startBlock, "latest", proposalId);
    if (receipts.length !== 1) {
      throw new Error(`Proposal not found: ${proposalId}`);
    }
    await monitor.monitorSingleProposal(receipts[0]);
  } else {
    await monitor.start();
  }
};

interface PipelineStage {
  name: string;
  identifier: string;
  status: string;
  explorerLink?: string;
  proposalLink?: string;
  children: PipelineStage[];
}

interface GovernorStatus {
  [governorAddress: string]: PipelineStage[];
}

class JsonLogger {
  constructor(public readonly fileLocation: string, public flushingIntervalMs: number) {}

  private data: GovernorStatus = {};
  private writing = false;

  private writeToFile() {
    const data = JSON.stringify(this.data, null, 2);
    fs.writeFileSync(this.fileLocation, data);
  }

  public stop() {
    this.writing = false;
  }

  public async start() {
    this.writing = true;
    while (this.writing) {
      this.writeToFile();
      await wait(this.flushingIntervalMs);
    }
  }

  public subscribeToMonitor(proposalMonitor: ProposalMonitor) {
    const emittedStages: Map<string, PipelineStage> = new Map();
    const originKey = `${proposalMonitor.originAddress}::`;

    proposalMonitor.on(TrackerEventName.TRACKER_ERRORED, (e: GPMErrorEvent) => {
      console.log("Emitted error event");
      console.error(e);
    });

    proposalMonitor.on(TrackerEventName.TRACKER_STATUS, (e: GPMEvent) => {
      try {
        if (!this.data[proposalMonitor.originAddress]) {
          this.data[proposalMonitor.originAddress] = [];
        }

        const key = `${e.originAddress}:${e.stage}:${e.identifier}`;
        const prevKey = `${e.originAddress}:${e.prevStage?.stage || ""}:${
          e.prevStage?.identifier || ""
        }`;

        let proposalLink: string | undefined;
        if (prevKey === originKey && e.stage === "GovernorQueueStage") {
          proposalLink =
            "https://www.tally.xyz/gov/arbitrum/proposal/" +
            BigNumber.from(e.identifier).toString();
        }

        // create a stage from this event
        const pipelineStage: PipelineStage = {
          name: e.stage,
          identifier: e.identifier,
          status: ProposalStageStatus[e.status],
          explorerLink: e.publicExecutionUrl,
          proposalLink,
          children: [],
        };

        if (prevKey === originKey && !emittedStages.has(key)) {
          this.data[proposalMonitor.originAddress].push(pipelineStage);
        } else if (!emittedStages.has(key)) {
          const prevStage = emittedStages.get(prevKey);
          if (!prevStage) {
            throw new Error(`Could not find prev stage ${prevKey} for ${key}`);
          }
          prevStage.children.push(pipelineStage);
        } else {
          throw new Error(`Could not find prev stage ${prevKey} for ${key}`);
        }

        // set the stage
        if (!emittedStages.has(key)) {
          emittedStages.set(key, pipelineStage);
        } else {
          emittedStages.get(key)!.status = pipelineStage.status;
        }
      } catch (err) {
        console.error(err);
      }
    });
  }
}

const main = async () => {
  if (options.writeMode && !ARB_KEY) throw new Error("env var ARB_KEY required");
  if (options.writeMode && !ETH_KEY) throw new Error("env var ETH_KEY required");

  const l1Provider = new JsonRpcProvider(options.l1RpcUrl);
  const l1SignerOrProvider = options.writeMode ? new Wallet(ETH_KEY, l1Provider) : l1Provider;
  const govChainProvider = new JsonRpcProvider(options.govChainRpcUrl);
  const govChainSignerOrProvider = options.writeMode
    ? new Wallet(ARB_KEY, govChainProvider)
    : govChainProvider;
  const novaProvider = new JsonRpcProvider(options.novaRpcUrl);
  const novaSignerOrProvider = options.writeMode ? new Wallet(ARB_KEY, novaProvider) : novaProvider;

  let jsonLogger;
  if (options.jsonOutputLocation) {
    jsonLogger = new JsonLogger(options.jsonOutputLocation, 1000);
    jsonLogger.start();
  }

  const stageFactory = new StageFactory(
    options.startBlock,
    govChainSignerOrProvider,
    l1SignerOrProvider,
    novaSignerOrProvider
  );

  let roundTrip;
  if (options.coreGovernorAddress) {
    console.log("Starting Core Governor Monitor");
    const coreGovMonitor = new GovernorProposalMonitor(
      options.coreGovernorAddress,
      getProvider(govChainSignerOrProvider)!,
      options.pollingIntervalSeconds * 1000,
      options.blockLag,
      options.startBlock,
      stageFactory,
      options.writeMode
    );
    roundTrip = startMonitor("RoundTrip", coreGovMonitor, jsonLogger, options.proposalId);
  }

  let treasury;
  if (options.treasuryGovernorAddress) {
    console.log("Starting Treasury Governor Monitor");
    const treasuryMonitor = new GovernorProposalMonitor(
      options.treasuryGovernorAddress,
      getProvider(govChainSignerOrProvider)!,
      options.pollingIntervalSeconds * 1000,
      options.blockLag,
      options.startBlock,
      stageFactory,
      options.writeMode
    );
    treasury = startMonitor("Treasury", treasuryMonitor, jsonLogger, options.proposalId);
  }

  let sevTwelve;
  if (options.sevenTwelveCouncilAddress) {
    console.log("Starting 7-12 Council Monitor");
    const sevenTwelveMonitor = new GnosisSafeProposalMonitor(
      options.sevenTwelveCouncilAddress,
      getProvider(govChainSignerOrProvider)!,
      options.pollingIntervalSeconds * 1000,
      options.blockLag,
      options.startBlock,
      stageFactory,
      options.writeMode
    );
    sevTwelve = startMonitor("7-12 Council", sevenTwelveMonitor, jsonLogger, options.proposalId);
  }

  await Promise.all([roundTrip, treasury, sevTwelve]);
};

main().then(() => console.log("Done."));
