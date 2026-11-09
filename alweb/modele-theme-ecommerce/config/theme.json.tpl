{
  "site": {
    "nom": {
      "type": "text",
      "default": "{{nom}}",
      "label": "Nom de la boutique"
    },
    "slogan": {
      "type": "text",
      "default": "Des produits choisis avec soin, livrés chez vous.",
      "label": "Slogan"
    }
  },
  "couleurs": {
    "primaire": {
      "type": "color",
      "default": "#0f766e",
      "label": "Couleur principale"
    },
    "secondaire": {
      "type": "color",
      "default": "#1f2937",
      "label": "Couleur secondaire"
    },
    "fond": {
      "type": "color",
      "default": "#ffffff",
      "label": "Fond"
    },
    "texte": {
      "type": "color",
      "default": "#1f2937",
      "label": "Texte"
    },
    "doux": {
      "type": "color",
      "default": "#f0fdfa",
      "label": "Fond des sections"
    },
    "promo": {
      "type": "color",
      "default": "#dc2626",
      "label": "Promotions et prix barrés"
    }
  },
  "typographie": {
    "police": {
      "type": "font",
      "default": "Inter, system-ui, -apple-system, Segoe UI, sans-serif",
      "label": "Police"
    },
    "taille": {
      "type": "size",
      "default": "16px",
      "label": "Taille du texte"
    }
  },
  "mise_en_page": {
    "largeur": {
      "type": "size",
      "default": "1200px",
      "label": "Largeur du contenu"
    },
    "barre_laterale": {
      "type": "bool",
      "default": false,
      "label": "Barre latérale du blog"
    }
  },
  "boutique": {
    "devise": {
      "type": "text",
      "default": "€",
      "label": "Devise affichée après les prix"
    },
    "bandeau": {
      "type": "text",
      "default": "Livraison offerte dès 50 € d'achat",
      "label": "Bandeau d'annonce (vide : aucun)"
    },
    "colonnes": {
      "type": "choice",
      "default": "3",
      "options": [
        "2",
        "3",
        "4"
      ],
      "label": "Produits par ligne"
    }
  },
  "logo": {
    "type": "image",
    "default": "images/logo.svg",
    "label": "Logo"
  },
  "menu": {
    "type": "links",
    "default": [
      {
        "label": "Accueil",
        "url": "/"
      },
      {
        "label": "Boutique",
        "url": "/boutique"
      },
      {
        "label": "À propos",
        "url": "/about"
      },
      {
        "label": "Contact",
        "url": "/contact"
      }
    ],
    "label": "Menu"
  },
  "reseaux": {
    "type": "links",
    "default": [
      {
        "label": "Instagram",
        "url": "https://www.instagram.com/"
      },
      {
        "label": "Facebook",
        "url": "https://www.facebook.com/"
      }
    ],
    "label": "Réseaux sociaux"
  },
  "pied": {
    "texte": {
      "type": "text",
      "default": "Paiement à la livraison · Retours sous 30 jours.",
      "label": "Texte du pied de page"
    }
  }
}
