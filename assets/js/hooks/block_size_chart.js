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
          label: 'Block Size (MB)',
          data: data.map(d => d.size_mb),
          borderColor: 'rgb(168, 85, 247)',
          backgroundColor: 'rgba(168, 85, 247, 0.1)',
          borderWidth: 2,
          fill: true,
          tension: 0.1,
          pointRadius: 0,
          pointHoverRadius: 5
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
                const sizeMB = context.parsed.y;
                const sizeBytes = (sizeMB * 1024 * 1024).toLocaleString();
                return [
                  'Size: ' + sizeMB.toFixed(2) + ' MB',
                  'Bytes: ' + sizeBytes
                ];
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
              text: 'Block Size (MB)'
            },
            beginAtZero: true,
            ticks: {
              callback: function(value) {
                return value.toFixed(1) + ' MB';
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
      this.chart.data.datasets[0].data = data.map(d => d.size_mb);

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
