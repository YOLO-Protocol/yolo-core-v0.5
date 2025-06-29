const https = require('https');

// Simulate the Functions.makeHttpRequest call
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

// Test the exact API call from the contract
async function testXAUPriceAPI() {
    console.log("=== Testing Coinbase API for XAU Price ===\n");
    
    try {
        console.log("1. Making HTTP request to Coinbase API...");
        const response = await makeHttpRequest({
            url: 'https://api.coinbase.com/v2/exchange-rates',
            method: 'GET'
        });
        
        console.log("2. Response status:", response.status);
        console.log("3. Response error:", response.error);
        
        if (response.error) {
            throw new Error('Request failed: ' + response.error);
        }
        
        console.log("4. Full response structure:");
        console.log(JSON.stringify(response.data, null, 2));
        
        const data = response.data;
        
        console.log("\n5. Checking data structure...");
        console.log("- data.data exists:", !!data.data);
        console.log("- data.data.rates exists:", !!(data.data && data.data.rates));
        console.log("- data.data.rates.XAU exists:", !!(data.data && data.data.rates && data.data.rates.XAU));
        
        if (!data.data || !data.data.rates || !data.data.rates.XAU) {
            throw new Error('Invalid response format - XAU rate not found');
        }
        
        const xauUsdRate = parseFloat(data.data.rates.XAU);
        console.log("\n6. XAU Rate Processing:");
        console.log("- Raw XAU rate:", data.data.rates.XAU);
        console.log("- Parsed XAU rate:", xauUsdRate);
        console.log("- Is valid number:", !isNaN(xauUsdRate) && xauUsdRate > 0);
        
        if (isNaN(xauUsdRate) || xauUsdRate <= 0) {
            throw new Error('Invalid XAU price: ' + xauUsdRate);
        }
        
        // Convert to 8 decimals like Chainlink price feeds
        const priceWith8Decimals = Math.round(xauUsdRate * 100000000);
        
        console.log("\n7. Final Price Calculation:");
        console.log("- XAU rate (USD per XAU):", xauUsdRate);
        console.log("- Price with 8 decimals:", priceWith8Decimals);
        console.log("- Expected format check:");
        console.log("  * Should be around 260000000000 (for ~$2600)");
        console.log("  * Actual result:", priceWith8Decimals);
        console.log("  * Difference indicates:", priceWith8Decimals < 1000000000 ? "WRONG UNIT (possibly XAU per USD instead of USD per XAU)" : "Correct format");
        
        // Test if we need to invert the rate
        const invertedRate = 1 / xauUsdRate;
        const invertedWith8Decimals = Math.round(invertedRate * 100000000);
        
        console.log("\n8. Inverted Rate Test (1/XAU rate):");
        console.log("- Inverted rate:", invertedRate);
        console.log("- Inverted with 8 decimals:", invertedWith8Decimals);
        console.log("- This looks more reasonable for XAU price:", invertedWith8Decimals > 200000000000);
        
        console.log("\n=== CONCLUSION ===");
        console.log("The API is likely returning XAU per USD (fractional) instead of USD per XAU.");
        console.log("We need to invert the rate: 1 / XAU_rate to get USD per XAU");
        
    } catch (error) {
        console.error("❌ Error:", error.message);
        if (error.details) {
            console.error("Details:", error.details);
        }
    }
}

// Run the test
testXAUPriceAPI();