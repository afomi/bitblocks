import { Network } from 'vis-network';

export default {
  mounted() {
    const data = JSON.parse(this.el.dataset.graphData);

    // Transform data for vis-network
    const nodes = data.nodes.map(node => ({
      id: node.id,
      label: node.label,
      title: node.id, // Tooltip shows full txid
      color: this.getNodeColor(node.level),
      level: node.level,
      font: { size: 14 }
    }));

    const edges = data.edges.map(edge => ({
      id: edge.id,
      from: edge.from,
      to: edge.to,
      arrows: 'to',
      label: edge.label,
      font: { size: 10, align: 'middle' }
    }));

    const container = this.el;
    const graphData = {
      nodes: nodes,
      edges: edges
    };

    const options = {
      layout: {
        hierarchical: {
          direction: 'LR', // Left to Right
          sortMethod: 'directed',
          levelSeparation: 250,
          nodeSpacing: 150,
          treeSpacing: 200
        }
      },
      physics: {
        enabled: false
      },
      nodes: {
        shape: 'box',
        margin: 10,
        widthConstraint: {
          maximum: 200
        }
      },
      edges: {
        smooth: {
          type: 'cubicBezier',
          forceDirection: 'horizontal'
        },
        arrows: {
          to: {
            enabled: true,
            scaleFactor: 0.5
          }
        }
      },
      interaction: {
        hover: true,
        tooltipDelay: 100,
        navigationButtons: true,
        keyboard: true
      }
    };

    this.network = new Network(container, graphData, options);

    // Handle node clicks
    this.network.on('click', (params) => {
      if (params.nodes.length > 0) {
        const nodeId = params.nodes[0];
        // Navigate to transaction page
        window.location.href = `/transactions/${nodeId}`;
      }
    });

    // Handle node hover
    this.network.on('hoverNode', () => {
      container.style.cursor = 'pointer';
    });

    this.network.on('blurNode', () => {
      container.style.cursor = 'default';
    });
  },

  updated() {
    const data = JSON.parse(this.el.dataset.graphData);

    if (this.network) {
      // Transform data for vis-network
      const nodes = data.nodes.map(node => ({
        id: node.id,
        label: node.label,
        title: node.id,
        color: this.getNodeColor(node.level),
        level: node.level,
        font: { size: 14 }
      }));

      const edges = data.edges.map(edge => ({
        id: edge.id,
        from: edge.from,
        to: edge.to,
        arrows: 'to',
        label: edge.label,
        font: { size: 10, align: 'middle' }
      }));

      this.network.setData({
        nodes: nodes,
        edges: edges
      });
    }
  },

  getNodeColor(level) {
    if (level === 0) {
      // Central node (the one we're looking at)
      return {
        background: '#3B82F6',
        border: '#2563EB',
        highlight: {
          background: '#2563EB',
          border: '#1D4ED8'
        }
      };
    } else if (level < 0) {
      // Input nodes (where value came from) - LEFT SIDE
      return {
        background: '#10B981',
        border: '#059669',
        highlight: {
          background: '#059669',
          border: '#047857'
        }
      };
    } else {
      // Output nodes (where value went to) - RIGHT SIDE
      return {
        background: '#F59E0B',
        border: '#D97706',
        highlight: {
          background: '#D97706',
          border: '#B45309'
        }
      };
    }
  },

  destroyed() {
    if (this.network) {
      this.network.destroy();
    }
  }
};
