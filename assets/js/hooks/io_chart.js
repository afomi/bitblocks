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
          label: 'Inputs per Block',
          data: data.map(d => d.input_count),
          borderColor: 'rgb(59, 130, 246)',
          backgroundColor: 'rgba(59, 130, 246, 0.1)',
          borderWidth: 2,
          fill: true,
          tension: 0.1,
          pointRadius: 0,
          pointHoverRadius: 5
        }, {
          label: 'Outputs per Block',
          data: data.map(d => d.output_count),
          borderColor: 'rgb(16, 185, 129)',
          backgroundColor: 'rgba(16, 185, 129, 0.1)',
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
            display: true,
            position: 'top'
          },
          tooltip: {
            callbacks: {
              title: function(context) {
                return 'Block ' + context[0].label;
              },
              label: function(context) {
                return context.dataset.label + ': ' + context.parsed.y.toLocaleString();
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
              text: 'Count'
            },
            beginAtZero: true
          }
        }
      }
    });
  },

  updated() {
    const data = JSON.parse(this.el.dataset.chartData);

    if (this.chart) {
      this.chart.data.labels = data.map(d => d.height);
      this.chart.data.datasets[0].data = data.map(d => d.input_count);
      this.chart.data.datasets[1].data = data.map(d => d.output_count);

      // Reset scales to fit new data
      this.chart.options.scales.x.min = undefined;
      this.chart.options.scales.x.max = undefined;
      this.chart.options.scales.y.min = undefined;
      this.chart.options.scales.y.max = undefined;

      // Force resize and update
      this.chart.resize();
      this.chart.update('none'); // No animation for better performance
    }
  },

  destroyed() {
    if (this.chart) {
      this.chart.destroy();
    }
  }
};
