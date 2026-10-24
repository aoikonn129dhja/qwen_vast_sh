import { app } from "/scripts/app.js";

const pendingKey = "qwen-runtime-pending-workflow";
let switching = false;

function inferModel(workflow, models) {
    const nodes = workflow?.nodes || [];
    const raw = JSON.stringify(nodes);
    const entries = Object.entries(models);
    const files = entries.filter(([, model]) =>
        (model.signatures?.model_files || []).some((name) => raw.includes(name)));
    if (files.length > 1) throw new Error("Workflow references multiple isolated models");
    if (files.length === 1) return files[0][0];
    const explicit = workflow?.extra?.qwen_model_id;
    if (explicit) {
        if (!models[explicit]) throw new Error(`Workflow model is not installed: ${explicit}`);
        return explicit;
    }
    const types = entries.filter(([, model]) =>
        (model.signatures?.node_types || []).some((type) => nodes.some((node) => node.type === type)));
    return types.length === 1 ? types[0][0] : null;
}

app.registerExtension({
    name: "qwen.runtime.automatic-selection",
    async init() {
        const original = app.loadGraphData;
        app.loadGraphData = async function (workflow, ...args) {
            if (switching) return;
            // Select before node validation: another backend may provide different nodes.
            const [modelsResponse, currentResponse] = await Promise.all([
                fetch("/runtime/models"), fetch("/runtime/current"),
            ]);
            if (!modelsResponse.ok || !currentResponse.ok) {
                throw new Error("Cannot read installed runtime models");
            }
            const models = await modelsResponse.json();
            const model = inferModel(workflow, models);
            const current = (await currentResponse.json()).model_id;
            if (model && (model !== current || !["BACKEND_READY", "RUNNING"].includes(models[model]?.state))) {
                switching = true;
                try {
                    const response = await fetch("/runtime/select", {
                        method: "POST", headers: { "Content-Type": "application/json" },
                        body: JSON.stringify({ model_id: model }),
                    });
                    if (!response.ok) throw new Error(await response.text());
                    sessionStorage.setItem(pendingKey, JSON.stringify(workflow));
                    window.location.reload();
                    return;
                } catch (error) {
                    switching = false;
                    throw error;
                }
            }
            return original.call(this, workflow, ...args);
        };
    },
    async setup() {
        const pending = sessionStorage.getItem(pendingKey);
        if (!pending) return;
        sessionStorage.removeItem(pendingKey);
        await app.loadGraphData(JSON.parse(pending));
    },
});
