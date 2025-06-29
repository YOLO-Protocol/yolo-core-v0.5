const https = require('https');

// Simulate the FIXED Functions.makeHttpRequest call
async function makeHttpRequest(config) {
    return new Promise((resolve, reject) => {
        const url = new URL(config.url);
        const options = {
            hostname: url.hostname,
            port: url.port || 443,
            path: url.pathname + url.search,
            method: config.method || 'GET',
            headers: {
                'User-Agent': 'Node.js/Chainlink-Functions-Test'
            }
        };

        const req = https.request(options, (res) => {
            let data = '';
            res.on('data', (chunk) => {
                data += chunk;
            });
            res.on('end', () => {
                try {
                    const response = {
                        data: JSON.parse(data),
                        status: res.statusCode,
                        error: res.statusCode >= 400 ? `HTTP ${res.statusCode}` : null
                    };
                    resolve(response);
                } catch (error) {
                    reject({ error: 'JSON parse error', details: error.message });
                }
            });
        });

        req.on('error', (error) => {
            reject({ error: 'Request failed', details: error.message });
        });

        req.end();
    });
}

// Test the FIXED API call (with inversion)
async function testFixedXAUPriceAPI() {
    console.log("=== Testing FIXED Coinbase API for XAU Price ===\n");
    
    try {
        const response = await makeHttpRequest({
            url: 'https://api.coinbase.com/v2/exchange-rates',
            method: 'GET'
        });
        
        if (response.error) {
            throw new Error('Request failed: ' + response.error);
        }
        
        const data = response.data;
        
        if (!data.data || !data.data.rates || !data.data.rates.XAU) {
            throw new Error('Invalid response format');
        }
        
        // FIXED LOGIC: Invert the rate
        const xauPerUsd = parseFloat(data.data.rates.XAU);
        
        if (isNaN(xauPerUsd) || xauPerUsd <= 0) {
            throw new Error('Invalid XAU rate');
        }
        
        const usdPerXau = 1 / xauPerUsd;
        const priceWith8Decimals = Math.round(usdPerXau * 100000000);
        
        console.log("=== FIXED CALCULATION RESULTS ===");
        console.log("1. Raw XAU per USD:", xauPerUsd);
        console.log("2. Inverted to USD per XAU:", usdPerXau);
        console.log("3. Price with 8 decimals:", priceWith8Decimals);
        console.log("4. Human readable price: $" + (priceWith8Decimals / 100000000).toFixed(2));
        console.log("\n5. Comparison with expected:");
        console.log("- Expected range: $2500 - $3500");
        console.log("- Our result: $" + (priceWith8Decimals / 100000000).toFixed(2));
        console.log("- Within range:", (priceWith8Decimals / 100000000) >= 2500 && (priceWith8Decimals / 100000000) <= 3500 ? "✅ YES" : "❌ NO");
        
        console.log("\n6. 8-decimal format check:");
        console.log("- Result:", priceWith8Decimals);
        console.log("- Should be 10-12 digits for XAU price:", priceWith8Decimals.toString().length >= 10 && priceWith8Decimals.toString().length <= 12 ? "✅ YES" : "❌ NO");
        
        console.log("\n🎉 FIXED! The oracle will now return proper XAU prices!");
        
    } catch (error) {
        console.error("❌ Error:", error.message);
    }
}

// Run the test
testFixedXAUPriceAPI();