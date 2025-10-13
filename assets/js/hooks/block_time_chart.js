import Chart from 'chart.js/auto';

export default {
  mounted() {
    const data = JSON.parse(this.el.dataset.chartData);

    const ctx = this.el.getContext('2d');
    this.chart = new Chart(ctx, {
      type: 'bar',
      data: {
        labels: data.map(d => d.height),
        datasets: [{
          label: 'Block Time Variance (minutes from target)',
          data: data.map(d => d.time_diff_minutes - 10), // Show variance from 10-minute target
          backgroundColor: data.map(d => {
            // Target is 10 minutes
            const variance = d.time_diff_minutes - 10;
            if (variance > 5) {
              // Significantly slower (red)
              return 'rgba(239, 68, 68, 0.7)';
            } else if (variance > 2) {
              // Slightly slower (orange)
              return 'rgba(251, 146, 60, 0.7)';
            } else if (variance < -2) {
              // Faster than target (blue)
              return 'rgba(59, 130, 246, 0.7)';
            } else {
              // Near target (green)
              return 'rgba(34, 197, 94, 0.7)';
            }
          }),
          borderColor: data.map(d => {
            const variance = d.time_diff_minutes - 10;
            if (variance > 5) {
              return 'rgb(239, 68, 68)';
            } else if (variance > 2) {
              return 'rgb(251, 146, 60)';
            } else if (variance < -2) {
              return 'rgb(59, 130, 246)';
            } else {
              return 'rgb(34, 197, 94)';
            }
          }),
          borderWidth: 1
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
            display: false
          },
          tooltip: {
            callbacks: {
              title: function(context) {
                return 'Block ' + context[0].label;
              },
              label: function(context) {
                const minutes = context.parsed.y;
                const variance = minutes - 10;
                const varianceText = variance > 0 ? '+' + variance.toFixed(1) : variance.toFixed(1);
                return [
                  'Time: ' + minutes.toFixed(1) + ' minutes',
                  'Variance: ' + varianceText + ' min from target',
                  'Target: 10 minutes'
                ];
              }
            }
          },
          annotation: {
            annotations: {
              targetLine: {
                type: 'line',
                yMin: 10,
                yMax: 10,
                borderColor: 'rgb(34, 197, 94)',
                borderWidth: 2,
                borderDash: [5, 5],
                label: {
                  content: 'Target: 10 minutes',
                  display: true,
                  position: 'end'
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
            title: {
              display: true,
              text: 'Variance from 10-Minute Target (minutes)'
            },
            beginAtZero: false,
            ticks: {
              callback: function(value) {
                return (value > 0 ? '+' : '') + value.toFixed(0);
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
      this.chart.data.datasets[0].data = data.map(d => d.time_diff_minutes - 10); // Show variance from 10-minute target

      // Update colors based on new data
      this.chart.data.datasets[0].backgroundColor = data.map(d => {
        const variance = d.time_diff_minutes - 10;
        if (variance > 5) {
          return 'rgba(239, 68, 68, 0.7)';
        } else if (variance > 2) {
          return 'rgba(251, 146, 60, 0.7)';
        } else if (variance < -2) {
          return 'rgba(59, 130, 246, 0.7)';
        } else {
          return 'rgba(34, 197, 94, 0.7)';
        }
      });

      this.chart.data.datasets[0].borderColor = data.map(d => {
        const variance = d.time_diff_minutes - 10;
        if (variance > 5) {
          return 'rgb(239, 68, 68)';
        } else if (variance > 2) {
          return 'rgb(251, 146, 60)';
        } else if (variance < -2) {
          return 'rgb(59, 130, 246)';
        } else {
          return 'rgb(34, 197, 94)';
        }
      });

      // Reset scales to fit new data
      this.chart.options.scales.x.min = undefined;
      this.chart.options.scales.x.max = undefined;
      this.chart.options.scales.y.min = undefined;
      this.chart.options.scales.y.max = undefined;

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
