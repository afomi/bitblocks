import Chart from 'chart.js/auto';

export default {
  mounted() {
    const data = JSON.parse(this.el.dataset.chartData);

    const ctx = this.el.getContext('2d');
    this.chart = new Chart(ctx, {
      type: 'line',
      data: {
        labels: data.map(d => d.height),
        datasets: [{
          label: 'Total Input Satoshis',
          data: data.map(d => d.total_inputs),
          borderColor: 'rgb(59, 130, 246)',
          backgroundColor: 'rgba(59, 130, 246, 0.1)',
          borderWidth: 2,
          fill: false,
          tension: 0.1,
          pointRadius: 0,
          pointHoverRadius: 5,
          yAxisID: 'y'
        }, {
          label: 'Total Output Satoshis',
          data: data.map(d => d.total_outputs),
          borderColor: 'rgb(34, 197, 94)',
          backgroundColor: 'rgba(34, 197, 94, 0.1)',
          borderWidth: 2,
          fill: false,
          tension: 0.1,
          pointRadius: 0,
          pointHoverRadius: 5,
          yAxisID: 'y'
        }, {
          label: 'Miner Fees',
          data: data.map(d => d.miner_fees),
          borderColor: 'rgb(234, 179, 8)',
          backgroundColor: 'rgba(234, 179, 8, 0.2)',
          borderWidth: 2,
          fill: true,
          tension: 0.1,
          pointRadius: 0,
          pointHoverRadius: 5,
          yAxisID: 'y-fees'
        }]
      },
      options: {
        responsive: true,
        maintainAspectRatio: true,
        interaction: {
          intersect: false,
          mode: 'index'
        },
        plugins: {
          legend: {
            display: true,
            position: 'top'
          },
          tooltip: {
            callbacks: {
              title: function(context) {
                return 'Block ' + context[0].label;
              },
              label: function(context) {
                const value = context.parsed.y;
                const bsv = (value / 100_000_000).toFixed(8);

                if (context.dataset.label === 'Miner Fees') {
                  return context.dataset.label + ': ' + value.toLocaleString() + ' sats (' + bsv + ' BSV)';
                } else {
                  return context.dataset.label + ': ' + value.toLocaleString() + ' sats (' + bsv + ' BSV)';
                }
              }
            }
          }
        },
        scales: {
          x: {
            title: {
              display: true,
              text: 'Block Height'
            },
            ticks: {
              maxTicksLimit: 10
            }
          },
          y: {
            type: 'linear',
            position: 'left',
            title: {
              display: true,
              text: 'Total Satoshis (Inputs/Outputs)'
            },
            beginAtZero: true,
            ticks: {
              callback: function(value) {
                // Format large numbers with K, M, B suffixes
                if (value >= 1000000000) {
                  return (value / 1000000000).toFixed(1) + 'B';
                } else if (value >= 1000000) {
                  return (value / 1000000).toFixed(1) + 'M';
                } else if (value >= 1000) {
                  return (value / 1000).toFixed(1) + 'K';
                }
                return value;
              }
            }
          },
          'y-fees': {
            type: 'linear',
            position: 'right',
            title: {
              display: true,
              text: 'Miner Fees (Satoshis)'
            },
            beginAtZero: true,
            grid: {
              drawOnChartArea: false
            },
            ticks: {
              callback: function(value) {
                if (value >= 1000000) {
                  return (value / 1000000).toFixed(1) + 'M';
                } else if (value >= 1000) {
                  return (value / 1000).toFixed(1) + 'K';
                }
                return value;
              }
            }
          }
        }
      }
    });
  },

  updated() {
    const data = JSON.parse(this.el.dataset.chartData);

    if (this.chart) {
      this.chart.data.labels = data.map(d => d.height);
      this.chart.data.datasets[0].data = data.map(d => d.total_inputs);
      this.chart.data.datasets[1].data = data.map(d => d.total_outputs);
      this.chart.data.datasets[2].data = data.map(d => d.miner_fees);

      // Reset scales to fit new data
      this.chart.options.scales.x.min = undefined;
      this.chart.options.scales.x.max = undefined;
      this.chart.options.scales.y.min = undefined;
      this.chart.options.scales.y.max = undefined;
      this.chart.options.scales['y-fees'].min = undefined;
      this.chart.options.scales['y-fees'].max = undefined;

      // Force resize and update
      this.chart.resize();
      this.chart.update('none');
    }
  },

  destroyed() {
    if (this.chart) {
      this.chart.destroy();
    }
  }
};
