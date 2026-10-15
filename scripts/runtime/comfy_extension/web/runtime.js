import { app } from "../../scripts/app.js";

const pendingKey = "qwen-runtime-pending-workflow";
let switching = false;

function inferModel(workflow, models) {
    const explicit = workflow?.extra?.qwen_model_id;
    if (explicit && models[explicit]) return explicit;
    const raw = JSON.stringify(workflow?.nodes || []);
    const matches = Object.entries(models).filter(([, entry]) => {
        const signature = entry.signatures || {};
        return (signature.node_types || []).some((type) =>
            (workflow?.nodes || []).some((node) => node.type === type)) ||
            (signature.model_files || []).some((name) => raw.includes(name));
    });
    return matches.length === 1 ? matches[0][0] : null;
}

async function switchForGraph() {
    if (switching) return;
    const workflow = app.graph?.serialize();
    if (!workflow || !workflow.nodes?.length) return;
    const [modelsResponse, currentResponse] = await Promise.all([
        fetch("/runtime/models"), fetch("/runtime/current"),
    ]);
    if (!modelsResponse.ok || !currentResponse.ok) return;
    const models = await modelsResponse.json();
    const current = (await currentResponse.json()).model_id;
    let model = inferModel(workflow, models);
    if (!model && Object.keys(models).length > 1) {
        const chosen = window.prompt(`Select model: ${Object.keys(models).join(", ")}`);
        if (!chosen || !models[chosen]) return;
        model = chosen;
    }
    if (!model || model === current) return;
    switching = true;
    try {
        const response = await fetch("/runtime/select", {
            method: "POST", headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ model_id: model }),
        });
        if (!response.ok) throw new Error(await response.text());
        sessionStorage.setItem(pendingKey, JSON.stringify(workflow));
        window.location.reload();
    } catch (error) {
        switching = false;
        window.alert(`Model switch failed: ${error.message}`);
    }
}

app.registerExtension({
    name: "qwen.runtime.switch",
    async setup() {
        const pending = sessionStorage.getItem(pendingKey);
        if (!pending) return;
        sessionStorage.removeItem(pendingKey);
        await app.loadGraphData(JSON.parse(pending));
    },
    async afterConfigureGraph() {
        await switchForGraph();
    },
});
